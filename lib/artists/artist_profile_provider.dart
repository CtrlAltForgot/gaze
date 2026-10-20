import '../library/artist_profile.dart';

abstract interface class ArtistProfileProvider {
  Future<ArtistProfile?> find(
    String name, {
    List<String> recordings = const [],
  });
}
