// 拖入图片设封面与下载书的同名封面（R1 后，用户反馈）：
// • 书库首页、书籍信息页拖入图片：打开“选择封面图片”弹窗并预先核验这张图，确认后才写入；
// • 书源下载的书加入书库时：TXT 旁有同名图片（插件下载的封面）且书还没有封面，就设为封面。
import 'dart:io';

import 'package:flutter/material.dart';

import '../../application/library_service.dart';
import '../errors.dart';
import 'cover_image_dialog.dart';

/// 能作为封面的图片扩展名（与“选择封面图片”接受的格式相同）。
const coverImageExtensions = {'png', 'jpg', 'jpeg', 'webp', 'gif', 'bmp'};

bool isCoverImagePath(String path) {
  final dot = path.lastIndexOf('.');
  return dot >= 0 &&
      coverImageExtensions.contains(path.substring(dot + 1).toLowerCase());
}

/// 为 [bookId] 打开封面图片弹窗（预先核验 [path]），确认后写入封面。
/// 返回给用户看的结果；取消时返回 null。
Future<String?> adoptCoverImage(
  BuildContext context,
  LibraryService library,
  String bookId,
  String path, {
  Future<String?> Function()? pickImage,
}) async {
  final session = library.openBookInformation(bookId);
  try {
    final choice = await showDialog<CoverImageChoice>(
      context: context,
      builder: (_) => CoverImageDialog(
        session: session,
        pickImage: pickImage ?? () async => null,
        initialFit: 'contain',
        initialPath: path,
      ),
    );
    if (choice == null) return null;
    await session.apply(
      await session.preview({
        'cover_path': choice.evidence.path,
        'cover_fit': choice.fit,
        'cover_crop': null,
        'cover_design': null,
      }),
    );
    return '已设为封面';
  } catch (e) {
    return deskErrorText(e, '封面没有设置，书的原封面保持不变。可以到“书籍信息”里重新选择图片。');
  } finally {
    session.dispose();
  }
}

/// 书源下载的书（[txtPath]）加入书库后：旁边有同名图片、书还没有封面时，设为封面。
/// 返回是否设置了封面；图片不能用时静默跳过，不影响导入。
Future<bool> bindSidecarCover(LibraryService library, String txtPath) async {
  final dot = txtPath.lastIndexOf('.');
  final stem = dot < 0 ? txtPath : txtPath.substring(0, dot);
  String? image;
  for (final ext in const ['jpg', 'jpeg', 'png', 'webp', 'gif']) {
    if (await File('$stem.$ext').exists()) {
      image = '$stem.$ext';
      break;
    }
  }
  if (image == null) return false;
  final key = txtPath.replaceAll('\\', '/').toLowerCase();
  final book = library.books.value
      .where((b) => b.path.replaceAll('\\', '/').toLowerCase() == key)
      .firstOrNull;
  if (book == null || (book.coverPath?.isNotEmpty ?? false)) return false;
  final session = library.openBookInformation(book.id);
  try {
    final evidence = await session.inspectImage(image);
    await session.apply(
      await session.preview({
        'cover_path': evidence.path,
        'cover_fit': 'contain',
        'cover_crop': null,
        'cover_design': null,
      }),
    );
    return true;
  } catch (_) {
    return false;
  } finally {
    session.dispose();
  }
}
