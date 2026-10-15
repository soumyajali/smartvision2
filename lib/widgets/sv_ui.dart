import 'package:flutter/material.dart';

import '../core/constants/app_colors.dart';

/// Shared building blocks so every screen uses the same spacing, borders and
/// typography (rounded cards with thin blue borders on navy).
class SvCard extends StatelessWidget {
  const SvCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(16),
    this.margin,
    this.highlight = false,
    this.borderColor,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final EdgeInsetsGeometry? margin;
  final bool highlight;
  final Color? borderColor;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: margin,
      padding: padding,
      decoration: BoxDecoration(
        gradient: highlight ? AppColors.heroGradient : AppColors.cardGradient,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: borderColor ??
              (highlight ? AppColors.borderStrong : AppColors.border),
        ),
      ),
      child: child,
    );
  }
}

class SvSectionTitle extends StatelessWidget {
  const SvSectionTitle(
    this.title, {
    super.key,
    this.subtitle,
    this.icon,
    this.trailing,
  });

  final String title;
  final String? subtitle;
  final IconData? icon;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        if (icon != null) ...[
          Container(
            padding: const EdgeInsets.all(7),
            decoration: BoxDecoration(
              color: AppColors.accentBlue.withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(icon, size: 18, color: AppColors.accentCyan),
          ),
          const SizedBox(width: 10),
        ],
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: const TextStyle(
                  color: AppColors.primaryText,
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                ),
              ),
              if (subtitle != null)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(
                    subtitle!,
                    style: const TextStyle(
                      color: AppColors.mutedText,
                      fontSize: 12,
                    ),
                  ),
                ),
            ],
          ),
        ),
        if (trailing != null) trailing!,
      ],
    );
  }
}

class SvStatusDot extends StatelessWidget {
  const SvStatusDot({super.key, required this.color, this.size = 8});

  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        boxShadow: [
          BoxShadow(color: color.withValues(alpha: 0.6), blurRadius: 6),
        ],
      ),
    );
  }
}

class SvPill extends StatelessWidget {
  const SvPill({
    super.key,
    required this.label,
    required this.color,
    this.icon,
  });

  final String label;
  final Color color;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withValues(alpha: 0.45)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null)
            Icon(icon, size: 13, color: color)
          else
            SvStatusDot(color: color, size: 7),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              label,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: color,
                fontSize: 11,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.2,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Small label/value tile used for real metrics (FPS, resolution, …).
class SvMetric extends StatelessWidget {
  const SvMetric({
    super.key,
    required this.label,
    required this.value,
    this.valueColor,
    this.icon,
  });

  final String label;
  final String value;
  final Color? valueColor;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: AppColors.primaryBackground.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.borderSubtle),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              if (icon != null) ...[
                Icon(icon, size: 12, color: AppColors.mutedText),
                const SizedBox(width: 4),
              ],
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: AppColors.mutedText,
                    fontSize: 11,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: valueColor ?? AppColors.primaryText,
              fontSize: 15,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

enum SvTone { info, success, warning, error }

class SvNotice extends StatelessWidget {
  const SvNotice({
    super.key,
    required this.message,
    this.icon,
    this.tone = SvTone.info,
    this.action,
  });

  final String message;
  final IconData? icon;
  final SvTone tone;
  final Widget? action;

  Color get _color {
    switch (tone) {
      case SvTone.info:
        return AppColors.accentCyan;
      case SvTone.success:
        return AppColors.success;
      case SvTone.warning:
        return AppColors.warning;
      case SvTone.error:
        return AppColors.error;
    }
  }

  IconData get _defaultIcon {
    switch (tone) {
      case SvTone.info:
        return Icons.info_outline_rounded;
      case SvTone.success:
        return Icons.check_circle_outline_rounded;
      case SvTone.warning:
        return Icons.warning_amber_rounded;
      case SvTone.error:
        return Icons.error_outline_rounded;
    }
  }

  @override
  Widget build(BuildContext context) {
    final color = _color;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon ?? _defaultIcon, color: color, size: 18),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  message,
                  style: const TextStyle(
                    color: AppColors.secondaryText,
                    fontSize: 12.5,
                    height: 1.4,
                  ),
                ),
                if (action != null) ...[
                  const SizedBox(height: 8),
                  action!,
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class SvEmptyState extends StatelessWidget {
  const SvEmptyState({
    super.key,
    required this.icon,
    required this.title,
    required this.message,
    this.action,
  });

  final IconData icon;
  final String title;
  final String message;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: AppColors.accentBlue.withValues(alpha: 0.1),
              border: Border.all(color: AppColors.border),
            ),
            child: Icon(icon, color: AppColors.accentCyan, size: 26),
          ),
          const SizedBox(height: 12),
          Text(
            title,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: AppColors.primaryText,
              fontSize: 14,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            message,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: AppColors.mutedText,
              fontSize: 12,
              height: 1.4,
            ),
          ),
          if (action != null) ...[
            const SizedBox(height: 12),
            action!,
          ],
        ],
      ),
    );
  }
}

class SvLogo extends StatelessWidget {
  const SvLogo({super.key, this.size = 32, this.radius = 9});

  final double size;
  final double radius;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(color: AppColors.borderStrong),
        boxShadow: [
          BoxShadow(
            color: AppColors.accentCyan.withValues(alpha: 0.18),
            blurRadius: 10,
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(radius - 1),
        child: Image.asset(
          'assets/logo.png',
          fit: BoxFit.cover,
          errorBuilder: (context, error, stackTrace) => const Icon(
            Icons.visibility_rounded,
            color: AppColors.accentCyan,
          ),
        ),
      ),
    );
  }
}

/// Formats a probability (0..1) as a percentage string.
String formatPercent(double value, {int digits = 0}) =>
    '${(value * 100).toStringAsFixed(digits)}%';
