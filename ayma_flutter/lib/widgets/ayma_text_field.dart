import 'package:flutter/material.dart';

import '../theme.dart';

class AymaTextField extends StatelessWidget {
  final TextEditingController controller;
  final String label;
  final bool obscureText;
  final TextInputType? keyboardType;
  final ValueChanged<String>? onSubmitted;
  final String? hint;
  final int? maxLines;
  final Widget? suffix;

  const AymaTextField({
    super.key,
    required this.controller,
    required this.label,
    this.obscureText = false,
    this.keyboardType,
    this.onSubmitted,
    this.hint,
    this.maxLines = 1,
    this.suffix,
  });

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      obscureText: obscureText,
      keyboardType: keyboardType,
      onSubmitted: onSubmitted,
      maxLines: maxLines,
      style: TextStyle(color: context.ac.fg, fontSize: 15),
      cursorColor: context.ac.accent,
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        suffixIcon: suffix,
        labelStyle: TextStyle(color: context.ac.fgMute, fontSize: 14),
        hintStyle: TextStyle(color: context.ac.fgMute),
        filled: true,
        fillColor: context.ac.bgElev,
        contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: context.ac.lineSoft),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: context.ac.lineSoft),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: context.ac.accent, width: 1.5),
        ),
      ),
    );
  }
}
