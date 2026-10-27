import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

/// Atomically publishes a completed sibling file without replacing a target.
/// The hard-link operation fails if [target] already exists, including when a
/// competing process creates it after a caller's preliminary existence check.
class SafeFilePublisher {
  SafeFilePublisher._();

  static Future<void> publishNoReplace(File staged, File target) async {
    final sourcePath = staged.absolute.path;
    final targetPath = target.absolute.path;
    final linked = Platform.isWindows
        ? _linkWindows(sourcePath, targetPath)
        : _linkPosix(sourcePath, targetPath);
    if (!linked) {
      if (await target.exists()) {
        throw FileSystemException('目标文件已存在，请选择新文件名。', targetPath);
      }
      throw FileSystemException('无法安全发布文件。', targetPath);
    }
  }

  static bool _linkWindows(String sourcePath, String targetPath) {
    final library = DynamicLibrary.open('kernel32.dll');
    final createHardLink = library
        .lookupFunction<
          Int32 Function(Pointer<Utf16>, Pointer<Utf16>, Pointer<Void>),
          int Function(Pointer<Utf16>, Pointer<Utf16>, Pointer<Void>)
        >('CreateHardLinkW');
    final target = targetPath.toNativeUtf16();
    final source = sourcePath.toNativeUtf16();
    try {
      // Win32 BOOL is nonzero on success; POSIX link uses zero instead.
      return createHardLink(target, source, nullptr) != 0;
    } finally {
      malloc.free(target);
      malloc.free(source);
    }
  }

  static bool _linkPosix(String sourcePath, String targetPath) {
    final library = Platform.isMacOS
        ? DynamicLibrary.open('/usr/lib/libSystem.B.dylib')
        : DynamicLibrary.open('libc.so.6');
    final link = library
        .lookupFunction<
          Int32 Function(Pointer<Utf8>, Pointer<Utf8>),
          int Function(Pointer<Utf8>, Pointer<Utf8>)
        >('link');
    final source = sourcePath.toNativeUtf8();
    final target = targetPath.toNativeUtf8();
    try {
      return link(source, target) == 0;
    } finally {
      malloc.free(source);
      malloc.free(target);
    }
  }
}
