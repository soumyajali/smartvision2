import 'package:flutter/material.dart';

/// Design tokens matching the SmartVision website: dark navy / midnight-blue
/// surfaces, cyan and blue highlights, restrained purple accents.
class AppColors {
  // Surfaces (midnight → navy, the website sidebar is #121A3D)
  static const Color primaryBackground = Color(0xFF070D1F);
  static const Color secondaryBackground = Color(0xFF0B1430);
  static const Color cardBackground = Color(0xFF0F1A38);
  static const Color elevatedSurface = Color(0xFF16244A);
  static const Color sidebar = Color(0xFF0C1533);

  // Accents
  static const Color accentBlue = Color(0xFF3B82F6);
  static const Color accentCyan = Color(0xFF38BDF8);
  static const Color accentPurple = Color(0xFF8B5CF6);

  // Legacy accent names (kept so existing screens keep compiling).
  static const Color primaryViolet = Color(0xFF4F7CF7);
  static const Color brightViolet = Color(0xFF8B5CF6);
  static const Color deepViolet = Color(0xFF3B4FD8);
  static const Color neonAccent = accentCyan;

  // Typography
  static const Color primaryText = Color(0xFFF8FAFF);
  static const Color secondaryText = Color(0xFFB8C7E5);
  static const Color mutedText = Color(0xFF7F8DB0);

  // Status & Semantics
  static const Color success = Color(0xFF10B981);
  static const Color warning = Color(0xFFF59E0B);
  static const Color error = Color(0xFFEF4444);

  // Thin blue borders
  static const Color border = Color(0x3D3B6FD8);
  static const Color borderSubtle = Color(0x1A8FB3FF);
  static const Color borderStrong = Color(0x803B82F6);

  // Backwards-compatible aliases
  static const Color primary = primaryViolet;
  static const Color secondary = brightViolet;
  static const Color aiFeature = neonAccent;
  static const Color background = primaryBackground;
  static const Color card = cardBackground;
  static const Color textMain = primaryText;
  static const Color textSecondary = secondaryText;

  // Gradients
  static const LinearGradient primaryGradient = LinearGradient(
    colors: [accentBlue, Color(0xFF4F46E5)],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );

  static const LinearGradient cardGradient = LinearGradient(
    colors: [Color(0xFF111D3E), Color(0xFF0D1734)],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );

  static const LinearGradient heroGradient = LinearGradient(
    colors: [Color(0xFF15265A), Color(0xFF0D1734)],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );

  static const LinearGradient neonGlowGradient = LinearGradient(
    colors: [Color(0x3338BDF8), Color(0x053B82F6)],
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
  );
}
