import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skytide/daily_launch_animation.dart';

void main() {
  testWidgets('the first tap reaches the destination during launch', (
    tester,
  ) async {
    String? savedDate;
    var taps = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: DailyLaunchAnimation(
            lastPlayedDate: null,
            savePlayedDate: (date) async {
              savedDate = date;
            },
            child: Center(
              child: TextButton(
                onPressed: () => taps++,
                child: const Text('打开'),
              ),
            ),
          ),
        ),
      ),
    );

    expect(find.byType(Image), findsOneWidget);
    await tester.tap(find.text('打开'));
    await tester.pump();

    expect(taps, 1);
    expect(find.byType(Image), findsNothing);
    expect(savedDate, isNotNull);
  });

  testWidgets('same-day restart shows the destination without animation', (
    tester,
  ) async {
    final now = DateTime.now();
    var saveCalls = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: DailyLaunchAnimation(
          lastPlayedDate: '${now.year}-${now.month}-${now.day}',
          savePlayedDate: (_) async {
            saveCalls++;
          },
          child: const Center(child: Text('首页')),
        ),
      ),
    );

    expect(find.text('首页'), findsOneWidget);
    expect(find.byType(Image), findsNothing);
    expect(saveCalls, 0);
  });
}
