import 'package:flutter/material.dart';

/// The control page's fixed surfaces.
///
/// Only the accent comes from the bike's own colour range. These surfaces stay
/// the same for every bike, so a pastel or a near-white gradient can never wash
/// a card out: no surface is ever painted with the gradient.
abstract final class SDSurface {
  /// The page behind the cards.
  static const page = Color(0xff0e0f12);

  /// A card.
  static const card = Color(0xff17181c);

  /// A card's hairline, and an inactive divider.
  static const border = Color(0xff24262b);

  /// A row inside a card. One step lighter than the card, so every tap target
  /// shows its own edge.
  static const row = Color(0xff1e2025);

  static const text = Color(0xfff2f3f5);

  /// A title, and an icon that is not accented.
  static const label = Color(0xff9ba0a8);

  /// A caption, and an unselected label.
  static const muted = Color(0xff6b6e76);
}
