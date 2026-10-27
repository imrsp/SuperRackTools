class Rack {
  const Rack({required this.id, required this.number, required this.name});
  final int id;
  final int number;
  final String name;

  factory Rack.fromRow(Map<String, Object?> row) => Rack(
    id: row['id']! as int,
    number: row['number']! as int,
    name: row['name']! as String,
  );
}

class SessionDraft {
  const SessionDraft({required this.path, required this.racks});
  final String path;
  final List<Rack> racks;
}
