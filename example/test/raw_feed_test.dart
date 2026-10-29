import 'dart:async';

import 'package:flutter_background_video_recorder_example/streams_controller.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late StreamController<int> source;
  late List<String> log;
  late RawFeed<int> feed;
  var closes = 0;

  setUp(() {
    source = StreamController<int>.broadcast(sync: true);
    log = [];
    closes = 0;
    feed = RawFeed<int>(
      bytesOf: (item) => item,
      onChanged: () {},
      onError: (_) {},
      retain: (item) => log.add('retain $item'),
      releaseItem: (item) => log.add('release $item'),
      droppedOf: (item) => item ~/ 100,
    );
  });

  tearDown(() => source.close());

  Future<void> open() => feed.addListener(
    () async => (
      stream: source.stream,
      close: () async {
        closes++;
      },
    ),
  );

  test(
    'the item on the stage is held until the next one replaces it',
    () async {
      await open();

      source.add(1);
      source.add(2);
      source.add(3);

      expect(log, [
        'retain 1',
        'retain 2',
        'release 1',
        'retain 3',
        'release 2',
      ]);
      expect(feed.latest.value, 3);
    },
  );

  test('closing releases the item that was held', () async {
    await open();
    source.add(5);

    await feed.close();

    expect(log.last, 'release 5');
    expect(feed.latest.value, isNull);
    expect(closes, 1);
  });

  test('a second listener does not hold or count anything twice', () async {
    await open();
    await feed.addListener(() async => throw StateError('must not reopen'));

    source.add(7);

    expect(feed.listeners, hasLength(2));
    expect(log, ['retain 7']);
    expect(feed.total, 1);
    expect(feed.listeners.map((l) => l.received), [1, 1]);
  });

  test('the dropped count follows the items', () async {
    await open();

    source.add(250);

    expect(feed.dropped, 2);
    await feed.close();
    expect(feed.dropped, 0);
  });

  test('removing a listener keeps the session until the last one', () async {
    await open();
    await feed.addListener(() async => throw StateError('must not reopen'));

    await feed.removeListener();
    expect(closes, 0);
    expect(feed.listeners, hasLength(1));

    await feed.removeListener();
    expect(closes, 1);
    expect(feed.isOpen, isFalse);
  });
}
