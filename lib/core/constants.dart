import 'package:flutter/material.dart';

/// アプリ全体の入力制限値
class AppLimits {
  AppLimits._();

  static const int titleMaxLength = 100;
  static const int memoMaxLength = 500;
  static const int tagNameMaxLength = 30;
  static const int playlistNameMaxLength = 50;
  static const int urlMaxLength = 500;
  static const int regionNameMaxLength = 20;
  static const int maxTagsPerItem = 20;
  static const int maxRegions = 10;
}

/// 入力フォーム共通のhintStyle
const kHintStyle = TextStyle(color: Color(0xFF757575), fontSize: 13); // grey[600]
