import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:chan/models/attachment.dart';
import 'package:chan/models/downloaded_thread.dart';
import 'package:chan/models/post.dart';
import 'package:chan/models/thread.dart';
import 'package:chan/services/imageboard.dart';
import 'package:chan/services/persistence.dart';
import 'package:chan/services/thread_downloader.dart';
import 'package:chan/sites/4chan.dart';
import 'package:dio/dio.dart';
import 'package:html/parser.dart' show parse;
import 'package:path_provider/path_provider.dart';

/// Minimal tomorrow-theme CSS bundled into exported ZIPs so thread_data.html
/// renders correctly when opened in a browser.
const _tomorrowCss = 'body{background:#1d1f21;color:#c5c8c6;font-family:arial,helvetica,sans-serif;font-size:10pt;margin:5px}'
    'div.thread{margin:0;clear:both}div.post{margin:4px 0;overflow:hidden}'
    'div.reply{background-color:#282a2e;border:1px solid #3a3d41;display:table;padding:2px;margin-left:20px;margin-bottom:4px}'
    'div.op{display:inline}div.post div.postInfo{display:block;width:100%}'
    'span.name{color:#c5c8c6;font-weight:700}span.subject{color:#b294bb;font-weight:700}'
    'span.dateTime{color:#c5c8c6;font-size:9pt}'
    'blockquote.postMessage{display:block;margin:4px 20px}'
    'span.quote{color:#b5bd68}.quotelink,.deadlink{color:#5f89ac;text-decoration:underline}'
    'a,a:visited{color:#81a2be;text-decoration:none}a:hover{color:#5f89ac}'
    'div.file{display:inline-block;float:left;margin:0 10px 5px 0}'
    'div.fileText{word-break:break-all}.fileThumb img{border:none;float:left}'
    'hr{border:none;border-top:1px solid #282a2e}';

sealed class KurobaImportResult {}

class KurobaImportSuccess extends KurobaImportResult {
	final String description;
	KurobaImportSuccess(this.description);
}

class KurobaImportFailure extends KurobaImportResult {
	final String error;
	KurobaImportFailure(this.error);
}

/// Imports a KurobaEx ZIP thread export into the Flutter chan app.
///
/// ZIP filename format: `{siteName}_{board}_{threadId}.zip`
/// ZIP contents: `thread_data.html`, `tomorrow.css`, and media files.
Future<KurobaImportResult> importKurobaZip(String zipPath) async {
	try {
		final zipFile = File(zipPath);
		if (!zipFile.existsSync()) {
			return KurobaImportFailure('File not found: $zipPath');
		}

		// 1. Parse filename to get siteName, board, threadId
		final basename = zipFile.uri.pathSegments.last;
		final withoutExt = basename.endsWith('.zip')
				? basename.substring(0, basename.length - 4)
				: basename;
		final parts = withoutExt.split('_');
		if (parts.length < 3) {
			return KurobaImportFailure('Unexpected filename format: $basename');
		}
		final threadIdStr = parts.last;
		final board = parts[parts.length - 2];
		final siteName = parts.sublist(0, parts.length - 2).join('_');
		final threadId = int.tryParse(threadIdStr);
		if (threadId == null) {
			return KurobaImportFailure('Could not parse thread ID from: $withoutExt');
		}
		if (board.contains('..') || board.contains('/') || board.contains('\\')) {
			return KurobaImportFailure('Invalid board name in filename: $board');
		}

		// 2. Find matching imageboard by siteType or name
		Imageboard? imageboard;
		for (final ib in ImageboardRegistry.instance.imageboards) {
			if (ib.site.siteType == siteName) {
				imageboard = ib;
				break;
			}
		}
		if (imageboard == null) {
			for (final ib in ImageboardRegistry.instance.imageboards) {
				if (ib.site.name.toLowerCase() == siteName.toLowerCase()) {
					imageboard = ib;
					break;
				}
			}
		}
		if (imageboard == null) {
			return KurobaImportFailure('No imageboard configured for site: $siteName');
		}

		// 3. Determine CDN host for building attachment URLs (4chan-specific)
		String? imageUrl;
		if (imageboard.site is Site4Chan) {
			imageUrl = (imageboard.site as Site4Chan).imageUrl;
		}

		// 4. Validate ZIP entries against path traversal before extraction
		{
			final inputStream = InputFileStream(zipPath);
			try {
				final archive = ZipDecoder().decodeStream(inputStream);
				for (final file in archive.files) {
					final name = file.name;
					if (name.contains('..') || name.startsWith('/') || name.startsWith('\\')) {
						return KurobaImportFailure('Unsafe ZIP entry: $name');
					}
				}
			} finally {
				await inputStream.close();
			}
		}

		// Extract ZIP to the thread's download directory
		final threadDir = Directory(
			'${Persistence.downloadsDirectory.path}/${imageboard.key}/$board/$threadId',
		);
		threadDir.createSync(recursive: true);
		await extractFileToDisk(zipPath, threadDir.path);

		// 5. Read thread_data.html, then remove non-media files
		final htmlFile = File('${threadDir.path}/thread_data.html');
		if (!htmlFile.existsSync()) {
			try { threadDir.deleteSync(recursive: true); } catch (_) {}
			return KurobaImportFailure('No thread_data.html found in ZIP');
		}
		final htmlContent = htmlFile.readAsStringSync();
		// Remove stylesheet and HTML; leave only media in the thread dir
		for (final name in ['thread_data.html', 'tomorrow.css']) {
			final f = File('${threadDir.path}/$name');
			if (f.existsSync()) f.deleteSync();
		}

		// Count remaining media files (mutable — may be updated after retry)
		var mediaFiles = threadDir
				.listSync()
				.whereType<File>()
				.map((f) => f.uri.pathSegments.last)
				.toSet();

		// 6. Parse HTML into posts
		final document = parse(htmlContent);
		final postContainers = document.querySelectorAll('div.postContainer');
		if (postContainers.isEmpty) {
			try { threadDir.deleteSync(recursive: true); } catch (_) {}
			return KurobaImportFailure('No posts found in thread_data.html');
		}

		final posts = <Post>[];
		DateTime? opTime;
		String? opSubject;
		List<Attachment> opAttachments = [];

		for (final container in postContainers) {
			final idAttr = container.attributes['id'] ?? '';
			if (!idAttr.startsWith('pc')) continue;
			final postId = int.tryParse(idAttr.substring(2));
			if (postId == null) continue;

			final isOp = container.classes.contains('opContainer');

			// Parse timestamp from "2023-07-15 06:04:45 No. 25512520"
			final dateTimeText =
					container.querySelector('span.dateTime')?.text.trim() ?? '';
			DateTime? postTime;
			if (dateTimeText.contains(' No. ')) {
				final datePart = dateTimeText.split(' No. ').first.trim();
				postTime = DateTime.tryParse(datePart);
			}
			postTime ??= DateTime.now();

			final nameText =
					container.querySelector('span.name')?.text.trim() ?? '';
			final subjectText =
					container.querySelector('span.subject')?.text.trim() ?? '';
			final commentHtml =
					container.querySelector('blockquote.postMessage')?.innerHtml ?? '';

			// Parse file attachments
			final attachments = <Attachment>[];
			for (final fileDiv in container.querySelectorAll('div.file')) {
				final fileLink = fileDiv.querySelector('div.fileText a');
				if (fileLink == null) continue;

				final cdnFilename = fileLink.attributes['href'] ?? '';
				if (cdnFilename.isEmpty) continue;

				final thumbnailSrc =
						fileDiv.querySelector('a.fileThumb img')?.attributes['src'] ?? '';

				// Link text: "1664577840710883.webm, 3.8 MB, 1024x576"
				final linkParts = fileLink.text.trim().split(', ');
				final originalFilename =
						linkParts.isNotEmpty ? linkParts[0] : cdnFilename;

				int? sizeBytes;
				int? width;
				int? height;
				if (linkParts.length >= 2) {
					sizeBytes = _parseSize(linkParts[1]);
				}
				if (linkParts.length >= 3) {
					final dims = linkParts[2].split('x');
					if (dims.length == 2) {
						width = int.tryParse(dims[0]);
						height = int.tryParse(dims[1]);
					}
				}

				final lastDot = cdnFilename.lastIndexOf('.');
				final cdnId =
						lastDot >= 0 ? cdnFilename.substring(0, lastDot) : cdnFilename;
				final cdnExt = lastDot >= 0 ? cdnFilename.substring(lastDot) : '';

				final String attUrl;
				final String thumbUrl;
				if (imageUrl != null) {
					attUrl =
							Uri.https(imageUrl, '/$board/$cdnFilename').toString();
					thumbUrl = thumbnailSrc.isNotEmpty
							? Uri.https(imageUrl, '/$board/$thumbnailSrc').toString()
							: Uri.https(imageUrl, '/$board/${cdnId}s.jpg').toString();
				} else {
					final baseUrl = imageboard.site.baseUrl;
					attUrl = 'https://$baseUrl/$board/$cdnFilename';
					thumbUrl = thumbnailSrc.isNotEmpty
							? 'https://$baseUrl/$board/$thumbnailSrc'
							: 'https://$baseUrl/$board/${cdnId}s.jpg';
				}

				attachments.add(Attachment(
					type: AttachmentType.fromFilename(cdnFilename),
					board: board,
					id: cdnId,
					ext: cdnExt,
					filename: originalFilename,
					url: attUrl,
					thumbnailUrl: thumbUrl,
					md5: '',
					width: width,
					height: height,
					threadId: threadId,
					sizeInBytes: sizeBytes,
				));
			}

			if (isOp) {
				opTime = postTime;
				opSubject = subjectText.isNotEmpty ? subjectText : null;
				opAttachments = List.from(attachments);
			}

			posts.add(Post(
				board: board,
				text: commentHtml,
				name: nameText,
				time: postTime,
				threadId: threadId,
				id: postId,
				spanFormat: imageboard.site is Site4Chan ? PostSpanFormat.chan4 : PostSpanFormat.stub,
				attachments_: attachments,
			));
		}

		if (posts.isEmpty) {
			return KurobaImportFailure('Failed to parse any posts from HTML');
		}

		// 6b. Verify extracted files match what HTML references; retry once if not.
		// Thumbnails are named "{cdnId}s.jpg" — only full-res CDN filenames are expected.
		final expectedFilenames = <String>{};
		for (final post in posts) {
			for (final att in post.attachments_) {
				final name = Uri.tryParse(att.url)?.pathSegments.lastOrNull;
				if (name != null && name.isNotEmpty) expectedFilenames.add(name);
			}
		}
		if (expectedFilenames.isNotEmpty) {
			final missing = expectedFilenames.difference(mediaFiles);
			if (missing.isNotEmpty) {
				// Re-extract and recount once — handles cases where extraction was interrupted
				await extractFileToDisk(zipPath, threadDir.path);
				for (final name in ['thread_data.html', 'tomorrow.css']) {
					final f = File('${threadDir.path}/$name');
					if (f.existsSync()) f.deleteSync();
				}
				mediaFiles = threadDir
						.listSync()
						.whereType<File>()
						.map((f) => f.uri.pathSegments.last)
						.toSet();
			}
		}
		final presentCount = expectedFilenames.isEmpty
				? mediaFiles.length
				: expectedFilenames.intersection(mediaFiles).length;
		final missingAfterRetry = expectedFilenames.isEmpty
				? 0
				: expectedFilenames.difference(mediaFiles).length;

		opTime ??= DateTime.now();

		// 7. Build Thread object
		final imageCount = posts.fold<int>(
			0,
			(sum, p) => sum + p.attachments_.length,
		);
		final thread = Thread(
			posts_: posts,
			isArchived: false,
			replyCount: posts.length - 1,
			imageCount: imageCount,
			id: threadId,
			board: board,
			title: opSubject,
			isSticky: false,
			time: opTime,
			attachments: opAttachments,
		);

		// 8. Persist thread so ThreadPage can display it without network
		await Persistence.setCachedThread(
			imageboard.key,
			board,
			threadId,
			thread,
		);

		// 9. Register the download record for the Downloads page listing
		final thumbnailUrl =
				opAttachments.isNotEmpty ? opAttachments.first.thumbnailUrl : null;
		await ThreadDownloadService.instance.registerImportedThread(
			imageboardKey: imageboard.key,
			board: board,
			threadId: threadId,
			title: opSubject,
			thumbnailUrl: thumbnailUrl,
			downloadedAt: opTime,
			totalFiles: mediaFiles.length,
		);

		final displayTitle = opSubject ?? '/$board/ #$threadId';
		final filesSummary = expectedFilenames.isEmpty
				? '${mediaFiles.length} files'
				: missingAfterRetry == 0
					? '$presentCount/${expectedFilenames.length} files'
					: '$presentCount/${expectedFilenames.length} files ($missingAfterRetry not in ZIP)';
		return KurobaImportSuccess(
			'Imported "$displayTitle" (${posts.length} posts, $filesSummary)',
		);
	} catch (e) {
		return KurobaImportFailure('Import failed: $e');
	}
}

/// Parses a human-readable file size string (e.g. "3.8 MB") into bytes.
int? _parseSize(String sizeStr) {
	final parts = sizeStr.trim().split(' ');
	if (parts.length != 2) return null;
	final value = double.tryParse(parts[0]);
	if (value == null) return null;
	switch (parts[1].toUpperCase()) {
		case 'B':
			return value.round();
		case 'KB':
			return (value * 1024).round();
		case 'MB':
			return (value * 1024 * 1024).round();
		case 'GB':
			return (value * 1024 * 1024 * 1024).round();
		default:
			return null;
	}
}

sealed class KurobaExportResult {}

class KurobaExportSuccess extends KurobaExportResult {
	final String zipPath;
	final String description;
	KurobaExportSuccess(this.zipPath, this.description);
}

class KurobaExportFailure extends KurobaExportResult {
	final String error;
	KurobaExportFailure(this.error);
}

/// Exports a downloaded thread as a KurobaEx-compatible ZIP archive.
///
/// The ZIP will contain:
/// - `thread_data.html` — a minimal KurobaEx-compatible HTML of the thread
/// - All media files from the thread dir (local files) or downloaded from CopyParty
///
/// Returns a [KurobaExportSuccess] with the path to the temporary ZIP file,
/// or a [KurobaExportFailure] with a description of what went wrong.
Future<KurobaExportResult> exportThreadAsZip(DownloadedThread record) async {
	try {
		final imageboard = ImageboardRegistry.instance.getImageboard(record.imageboardKey);
		if (imageboard == null) {
			return KurobaExportFailure('No imageboard found for key: ${record.imageboardKey}');
		}

		// Retrieve cached thread for HTML generation
		final thread = await Persistence.getCachedThread(record.imageboardKey, record.board, record.threadId);

		// Gather local media files
		final threadDir = Directory(
			'${Persistence.downloadsDirectory.path}/${record.imageboardKey}/${record.board}/${record.threadId}',
		);

		final Map<String, File> localFiles = {};
		final Map<String, List<int>> remoteContents = {};

		if (threadDir.existsSync()) {
			for (final entity in threadDir.listSync()) {
				if (entity is! File) continue;
				final name = entity.uri.pathSegments.last;
				if (name.endsWith('.part')) continue;
				localFiles[name] = entity;
			}
		}

		// For CopyParty-synced threads, fetch any files that aren't local
		if (record.syncedFiles > 0 && Persistence.settings.copypartyEnabled) {
			final serverUrl = Persistence.settings.copypartyServerUrl;
			final destRoot = Persistence.settings.copypartyDestRoot;
			if (serverUrl.isNotEmpty) {
				final base = serverUrl.endsWith('/') ? serverUrl.substring(0, serverUrl.length - 1) : serverUrl;
				final baseRoot = destRoot.endsWith('/') ? destRoot.substring(0, destRoot.length - 1) : destRoot;
				final password = await ThreadDownloadService.instance.getCopypartyPassword() ?? '';
				// Build the listing URI: path ends with the thread dir, ?ls is a query param
				final listUri = Uri.parse('$base$baseRoot/${record.imageboardKey}/${record.board}/${record.threadId}/').replace(
					queryParameters: {
						'ls': '',
						if (password.isNotEmpty) 'pw': password,
					},
				);
				final dio = Dio()..options.connectTimeout = 15000..options.receiveTimeout = 30000;
				try {
					final resp = await dio.getUri<Map<String, dynamic>>(listUri);
					final files = (resp.data?['files'] as List?)?.cast<Map<String, dynamic>>() ?? [];
					for (final f in files) {
						final name = f['fn'] as String? ?? f['n'] as String? ?? '';
						if (name.isEmpty || name.endsWith('.part')) continue;
						if (name.contains('..') || name.contains('/') || name.contains('\\')) continue;
						if (localFiles.containsKey(name)) continue;
						if (remoteContents.containsKey(name)) continue;
						final remoteUri = Uri.parse('$base$baseRoot/${record.imageboardKey}/${record.board}/${record.threadId}/$name');
						try {
							final headers = password.isNotEmpty ? {'Pw': password} : <String, String>{};
							final fileResp = await dio.getUri<List<int>>(remoteUri, options: Options(headers: headers, responseType: ResponseType.bytes));
							if (fileResp.data != null) {
								remoteContents[name] = fileResp.data!;
							}
						} catch (_) {
							// Skip files that fail to download
						}
					}
				} catch (_) {
					// If we can't list CopyParty, just use what we have locally
				} finally {
					dio.close();
				}
			}
		}

		if (localFiles.isEmpty && remoteContents.isEmpty && thread == null) {
			return KurobaExportFailure('No files found for this thread. The thread may have been deleted or moved.');
		}

		// Generate thread_data.html
		final htmlContent = _generateThreadHtml(
			thread: thread,
			record: record,
			imageboard: imageboard,
		);

		// Build the ZIP in a temp directory
		final tempDir = await getTemporaryDirectory();
		final siteName = imageboard.site.siteType;
		final zipName = '${siteName}_${record.board}_${record.threadId}.zip';
		final zipPath = '${tempDir.path}/$zipName';

		final encoder = ZipFileEncoder();
		try {
			encoder.create(zipPath);
			// Add thread_data.html
			final htmlBytes = utf8.encode(htmlContent);
			encoder.addArchiveFile(ArchiveFile('thread_data.html', htmlBytes.length, htmlBytes));

			// Add tomorrow.css so the HTML renders correctly in a browser
			final cssBytes = utf8.encode(_tomorrowCss);
			encoder.addArchiveFile(ArchiveFile('tomorrow.css', cssBytes.length, cssBytes));

			// Add local media files by streaming from disk (avoids loading into RAM)
			for (final entry in localFiles.entries) {
				await encoder.addFile(entry.value, entry.key);
			}
			// Add remote (CopyParty) media files from memory
			for (final entry in remoteContents.entries) {
				encoder.addArchiveFile(ArchiveFile(entry.key, entry.value.length, entry.value));
			}

			await encoder.close();
		} catch (e) {
			// Close the encoder (ignore errors) and delete the partial ZIP
			try { await encoder.close(); } catch (_) {}
			try { await File(zipPath).delete(); } catch (_) {}
			rethrow;
		}

		final fileCount = localFiles.length + remoteContents.length;
		return KurobaExportSuccess(
			zipPath,
			'Exported ${thread?.posts_.length ?? 0} posts with $fileCount file${fileCount == 1 ? '' : 's'}',
		);
	} catch (e) {
		return KurobaExportFailure('Export failed: $e');
	}
}

/// Generates a minimal KurobaEx-compatible thread_data.html from [thread].
/// If [thread] is null (not cached), generates a stub HTML with thread metadata only.
String _generateThreadHtml({
	required Thread? thread,
	required DownloadedThread record,
	required Imageboard imageboard,
}) {
	final board = record.board;
	final threadId = record.threadId;
	final title = record.title ?? thread?.title ?? '';

	if (thread == null) {
		final escapedTitle = _htmlEscape(title);
		return '''<!DOCTYPE html>
<html><head><meta charset="UTF-8"><title>/$board/ - Thread #$threadId</title>
<link rel="stylesheet" href="tomorrow.css">
</head>
<body>
<div class="thread" id="t$threadId">
  <div id="pc$threadId" class="postContainer opContainer">
    <div class="post op">
      <div class="postInfo">
        <span class="subject">$escapedTitle</span>
        <span class="dateTime">${record.downloadedAt.toIso8601String()} No. $threadId</span>
      </div>
      <blockquote class="postMessage">(Thread data not available — only media files exported)</blockquote>
    </div>
  </div>
</div>
</body></html>''';
	}

	final buf = StringBuffer();
	buf.writeln('<!DOCTYPE html>');
	buf.writeln('<html><head><meta charset="UTF-8">');
	buf.writeln('<title>/$board/ - ${_htmlEscape(title)}</title>');
	buf.writeln('<link rel="stylesheet" href="tomorrow.css">');
	buf.writeln('</head><body>');
	buf.writeln('<div class="thread" id="t$threadId">');

	for (final post in thread.posts_) {
		final isOp = post.id == threadId;
		final containerClass = isOp ? 'postContainer opContainer' : 'postContainer replyContainer';
		buf.writeln('<div id="pc${post.id}" class="$containerClass">');
		buf.writeln('<div class="post ${isOp ? 'op' : 'reply'}">');
		buf.writeln('<div class="postInfo">');
		if (isOp && title.isNotEmpty) {
			buf.writeln('<span class="subject">${_htmlEscape(title)}</span>');
		}
		buf.writeln('<span class="name">${_htmlEscape(post.name)}</span>');
		final dateStr = '${post.time.year}-${post.time.month.toString().padLeft(2, '0')}-${post.time.day.toString().padLeft(2, '0')} '
				'${post.time.hour.toString().padLeft(2, '0')}:${post.time.minute.toString().padLeft(2, '0')}:${post.time.second.toString().padLeft(2, '0')}';
		buf.writeln('<span class="dateTime">$dateStr No. ${post.id}</span>');
		buf.writeln('</div>'); // postInfo

		// File attachments
		for (final att in post.attachments_) {
			final cdnFilename = Uri.tryParse(att.url)?.pathSegments.lastOrNull ?? '';
			final thumbFilename = Uri.tryParse(att.thumbnailUrl)?.pathSegments.lastOrNull ?? '';
			final sizeStr = att.sizeInBytes != null ? _formatSize(att.sizeInBytes!) : '';
			final dimStr = (att.width != null && att.height != null) ? '${att.width}x${att.height}' : '';
			final linkText = [att.filename, if (sizeStr.isNotEmpty) sizeStr, if (dimStr.isNotEmpty) dimStr].join(', ');
			buf.writeln('<div class="file">');
			buf.writeln('<div class="fileText"><a href="$cdnFilename">${_htmlEscape(linkText)}</a></div>');
			buf.writeln('<a class="fileThumb"><img src="$thumbFilename"></a>');
			buf.writeln('</div>');
		}

		buf.writeln('<blockquote class="postMessage">${post.text}</blockquote>');
		buf.writeln('</div>'); // post
		buf.writeln('</div>'); // postContainer
	}

	buf.writeln('</div>'); // thread
	buf.writeln('</body></html>');
	return buf.toString();
}

String _htmlEscape(String s) => s
		.replaceAll('&', '&amp;')
		.replaceAll('<', '&lt;')
		.replaceAll('>', '&gt;')
		.replaceAll('"', '&quot;');

String _formatSize(int bytes) {
	if (bytes < 1024) return '$bytes B';
	if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
	if (bytes < 1024 * 1024 * 1024) return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
	return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
}
