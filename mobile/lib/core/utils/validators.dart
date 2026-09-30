/// Client-side checks mirror the backend rules so users get instant feedback.
/// The backend validates again; these never replace it.
class Validators {
  static final _email = RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$');
  static final _phone = RegExp(r'^\+[1-9]\d{7,14}$');
  static final _registration = RegExp(r'^[A-Z0-9-]{2,20}$');

  static String? email(String? v) {
    if (v == null || v.trim().isEmpty) return 'Enter your email address';
    if (!_email.hasMatch(v.trim())) return 'Enter a valid email address';
    return null;
  }

  static String? password(String? v) {
    if (v == null || v.length < 10) return 'At least 10 characters';
    if (v.length > 128) return 'At most 128 characters';
    if (!v.contains(RegExp(r'[A-Za-z]')) || !v.contains(RegExp(r'\d'))) {
      return 'Use at least one letter and one digit';
    }
    return null;
  }

  static String? required(String? v, [String what = 'This field']) =>
      (v == null || v.trim().isEmpty) ? '$what is required' : null;

  static String? name(String? v) {
    if (v == null || v.trim().length < 2) return 'Enter at least 2 characters';
    if (v.trim().length > 120) return 'At most 120 characters';
    return null;
  }

  static String? optionalPhone(String? v) {
    if (v == null || v.trim().isEmpty) return null;
    return _phone.hasMatch(v.trim()) ? null : 'Use international format, e.g. +923001234567';
  }

  static String? registrationNumber(String? v) {
    final value = (v ?? '').toUpperCase().replaceAll(' ', '');
    if (value.isEmpty) return 'Registration number is required for emergency vehicles';
    return _registration.hasMatch(value) ? null : 'Letters, digits and "-" only';
  }

  static String? number(String? v, {required double min, required double max}) {
    final value = double.tryParse((v ?? '').trim());
    if (value == null) return 'Enter a number';
    if (value < min || value > max) return 'Between $min and $max';
    return null;
  }
}
