List<String> profilePhotosFrom(Map<String, dynamic> profile) {
  final seen = <String>{};
  final ordered = <String>[];

  void addAll(Iterable<String> urls) {
    for (final raw in urls) {
      final url = raw.trim();
      if (url.isEmpty || seen.contains(url)) continue;
      seen.add(url);
      ordered.add(url);
    }
  }

  addAll((profile['photos'] as List?)?.whereType<String>() ?? const []);
  addAll((profile['photo_order'] as List?)?.whereType<String>() ?? const []);

  final single = (profile['photo_url'] as String?)?.trim();
  if (single != null && single.isNotEmpty) {
    addAll([single]);
  }

  return ordered;
}

String? profilePrimaryPhotoUrl(Map<String, dynamic> profile) {
  final photos = profilePhotosFrom(profile);
  return photos.isEmpty ? null : photos.first;
}
