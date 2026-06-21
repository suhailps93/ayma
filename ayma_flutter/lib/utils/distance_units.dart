// Locale-aware distance display: km vs miles based on user region/country.
import 'package:flutter/widgets.dart';

class DistanceUnits {
  static const double _kmToMiles = 0.621371;

  static bool usesMiles({
    String? locationRegion,
    String? countryCode,
  }) {
    final cc = (countryCode ?? '').trim().toUpperCase();
    if (cc == 'US') return true;
    if (cc == 'IN') return false;

    final loc = (locationRegion ?? '').trim().toLowerCase();
    if (loc.isEmpty) return false;
    if (loc.contains('united states') ||
        loc.contains('usa') ||
        loc.contains(', us') ||
        loc.endsWith(' us') ||
        loc.contains('america')) {
      return true;
    }
    if (loc.contains('india') || loc.contains('bharat') || loc.contains(', in')) {
      return false;
    }
    return false;
  }

  static String shortUnit({
    String? locationRegion,
    String? countryCode,
  }) {
    return usesMiles(locationRegion: locationRegion, countryCode: countryCode)
        ? 'mi'
        : 'km';
  }

  static int fromKm(
    int km, {
    String? locationRegion,
    String? countryCode,
  }) {
    if (!usesMiles(locationRegion: locationRegion, countryCode: countryCode)) {
      return km;
    }
    return (km * _kmToMiles).round();
  }

  static int toKm(
    int value, {
    String? locationRegion,
    String? countryCode,
  }) {
    if (!usesMiles(locationRegion: locationRegion, countryCode: countryCode)) {
      return value;
    }
    return (value / _kmToMiles).round();
  }

  static String formatFromKm(
    int km, {
    String? locationRegion,
    String? countryCode,
  }) {
    final value =
        fromKm(km, locationRegion: locationRegion, countryCode: countryCode);
    final unit =
        shortUnit(locationRegion: locationRegion, countryCode: countryCode);
    return '$value $unit';
  }

  static String countryCodeFromContext(BuildContext context) {
    return Localizations.localeOf(context).countryCode ?? '';
  }
}
