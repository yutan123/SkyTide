/// Coalesces automatic checks and records the date only after a successful probe.
class OtaDailyCheck {
  Future<void>? _inFlight;

  Future<void> run<T>({
    required String date,
    required Future<String?> Function() readDate,
    required Future<void> Function(String) writeDate,
    required Future<T> Function() probe,
    required Future<void> Function(T) onResult,
  }) => _inFlight ??= _run(
    date: date,
    readDate: readDate,
    writeDate: writeDate,
    probe: probe,
    onResult: onResult,
  ).whenComplete(() => _inFlight = null);

  Future<void> _run<T>({
    required String date,
    required Future<String?> Function() readDate,
    required Future<void> Function(String) writeDate,
    required Future<T> Function() probe,
    required Future<void> Function(T) onResult,
  }) async {
    if (await readDate() == date) return;
    final result = await probe();
    await writeDate(date);
    await onResult(result);
  }
}
