// Copyright 2014 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

// @dart = 2.8

import 'dart:convert';

import 'package:file/file.dart';
import 'package:file/memory.dart';
import 'package:flutter_tools/src/base/io.dart';
import 'package:flutter_tools/src/base/logger.dart';
import 'package:flutter_tools/src/base/os.dart';
import 'package:flutter_tools/src/base/platform.dart';
import 'package:flutter_tools/src/doctor.dart';
import 'package:flutter_tools/src/doctor_validator.dart';
import 'package:flutter_tools/src/project.dart';
import 'package:flutter_tools/src/reporting/reporting.dart';
import 'package:http/http.dart';
import 'package:http/testing.dart';

import '../src/common.dart';
import '../src/fake_http_client.dart';
import '../src/fake_process_manager.dart';

void main() {
  BufferLogger logger;
  FileSystem fs;
  TestUsage testUsage;
  Platform platform;
  OperatingSystemUtils operatingSystemUtils;

  setUp(() async {
    logger = BufferLogger.test();
    fs = MemoryFileSystem.test();
    testUsage = TestUsage();

    platform = FakePlatform(environment: <String, String>{}, operatingSystem: 'linux');
    operatingSystemUtils = OperatingSystemUtils(
      fileSystem: fs,
      logger: logger,
      platform: platform,
      processManager: FakeProcessManager.any(),
    );

    MockCrashReportSender.sendCalls = 0;
  });

  Future<void> verifyCrashReportSent(RequestInfo crashInfo, {
    int crashes = 1,
  }) async {
    // Verify that we sent the crash report.
    expect(crashInfo.method, 'POST');
    expect(crashInfo.uri, Uri(
      scheme: 'https',
      host: 'clients2.google.com',
      port: 443,
      path: '/cr/report',
      queryParameters: <String, String>{
        'product': 'Flutter_Tools',
        'version': 'test-version',
      },
    ));
    expect(crashInfo.fields['uuid'], testUsage.clientId);
    expect(crashInfo.fields['product'], 'Flutter_Tools');
    expect(crashInfo.fields['version'], 'test-version');
    expect(crashInfo.fields['osName'], 'linux');
    expect(crashInfo.fields['osVersion'], 'Linux');
    expect(crashInfo.fields['type'], 'DartError');
    expect(crashInfo.fields['error_runtime_type'], 'StateError');
    expect(crashInfo.fields['error_message'], 'Bad state: Test bad state error');
    expect(crashInfo.fields['comments'], 'crash');

    expect(logger.traceText, contains('Sending crash report to Google.'));
    expect(logger.traceText, contains('Crash report sent (report ID: test-report-id)'));
  }

  testWithoutContext('CrashReporter.informUser provides basic instructions', () async {
    final CrashReporter crashReporter = CrashReporter(
      fileSystem: fs,
      logger: logger,
      flutterProjectFactory: FlutterProjectFactory(fileSystem: fs, logger: logger),
      client: FakeHttpClient.any(),
    );

    final File file = fs.file('flutter_00.log');

    await crashReporter.informUser(
      CrashDetails(
        command: 'arg1 arg2 arg3',
        error: Exception('Dummy exception'),
        stackTrace: StackTrace.current,
        doctorText: 'Fake doctor text'),
      file,
    );

    expect(logger.errorText, contains('A crash report has been written to ${file.path}.'));
    expect(logger.statusText, contains('https://github.com/flutter/flutter/issues/new'));
  });

  testWithoutContext('suppress analytics', () async {
    testUsage.suppressAnalytics = true;

    final CrashReportSender crashReportSender = CrashReportSender(
      client: CrashingCrashReportSender(const SocketException('no internets')),
      usage: testUsage,
      platform: platform,
      logger: logger,
      operatingSystemUtils: operatingSystemUtils,
    );

    await crashReportSender.sendReport(
      error: StateError('Test bad state error'),
      stackTrace: null,
      getFlutterVersion: () => 'test-version',
      command: 'crash',
    );

    expect(logger.traceText, isEmpty);
  });

  group('allow analytics', () {
    setUp(() async {
      testUsage.suppressAnalytics = false;
    });

    testWithoutContext('should send crash reports', () async {
      final RequestInfo requestInfo = RequestInfo();

      final CrashReportSender crashReportSender = CrashReportSender(
        client: MockCrashReportSender(requestInfo),
        usage: testUsage,
        platform: platform,
        logger: logger,
        operatingSystemUtils: operatingSystemUtils,
      );

      await crashReportSender.sendReport(
        error: StateError('Test bad state error'),
        stackTrace: null,
        getFlutterVersion: () => 'test-version',
        command: 'crash',
      );

      await verifyCrashReportSent(requestInfo);
    });

    testWithoutContext('should print an explanatory message when there is a SocketException', () async {
      final CrashReportSender crashReportSender = CrashReportSender(
        client: CrashingCrashReportSender(const SocketException('no internets')),
        usage: testUsage,
        platform: platform,
        logger: logger,
        operatingSystemUtils: operatingSystemUtils,
      );

      await crashReportSender.sendReport(
        error: StateError('Test bad state error'),
        stackTrace: null,
        getFlutterVersion: () => 'test-version',
        command: 'crash',
      );

      expect(logger.errorText, contains('Failed to send crash report due to a network error'));
    });

    testWithoutContext('should print an explanatory message when there is an HttpException', () async {
      final CrashReportSender crashReportSender = CrashReportSender(
        client: CrashingCrashReportSender(const HttpException('no internets')),
        usage: testUsage,
        platform: platform,
        logger: logger,
        operatingSystemUtils: operatingSystemUtils,
      );

      await crashReportSender.sendReport(
        error: StateError('Test bad state error'),
        stackTrace: null,
        getFlutterVersion: () => 'test-version',
        command: 'crash',
      );

      expect(logger.errorText, contains('Failed to send crash report due to a network error'));
    });

    testWithoutContext('should print an explanatory message when there is a ClientException', () async {
      final CrashReportSender crashReportSender = CrashReportSender(
        client: CrashingCrashReportSender(const HttpException('no internets')),
        usage: testUsage,
        platform: platform,
        logger: logger,
        operatingSystemUtils: operatingSystemUtils,
      );

      await crashReportSender.sendReport(
        error: ClientException('Test bad state error'),
        stackTrace: null,
        getFlutterVersion: () => 'test-version',
        command: 'crash',
      );

      expect(logger.errorText, contains('Failed to send crash report due to a network error'));
    });

    testWithoutContext('should send only one crash report when sent many times', () async {
      final RequestInfo requestInfo = RequestInfo();

      final CrashReportSender crashReportSender = CrashReportSender(
        client: MockCrashReportSender(requestInfo),
        usage: testUsage,
        platform: platform,
        logger: logger,
        operatingSystemUtils: operatingSystemUtils,
      );

      await crashReportSender.sendReport(
        error: StateError('Test bad state error'),
        stackTrace: null,
        getFlutterVersion: () => 'test-version',
        command: 'crash',
      );

      await crashReportSender.sendReport(
        error: StateError('Test bad state error'),
        stackTrace: null,
        getFlutterVersion: () => 'test-version',
        command: 'crash',
      );

      await crashReportSender.sendReport(
        error: StateError('Test bad state error'),
        stackTrace: null,
        getFlutterVersion: () => 'test-version',
        command: 'crash',
      );

      await crashReportSender.sendReport(
        error: StateError('Test bad state error'),
        stackTrace: null,
        getFlutterVersion: () => 'test-version',
        command: 'crash',
      );

      expect(MockCrashReportSender.sendCalls, 1);
      await verifyCrashReportSent(requestInfo, crashes: 4);
    });

    testWithoutContext('should not send a crash report if on a user-branch', () async {
      String method;
      Uri uri;

      final MockClient mockClient = MockClient((Request request) async {
        method = request.method;
        uri = request.url;

        return Response(
          'test-report-id',
          200,
        );
      });

      final CrashReportSender crashReportSender = CrashReportSender(
        client: mockClient,
        usage: testUsage,
        platform: platform,
        logger: logger,
        operatingSystemUtils: operatingSystemUtils,
      );

      await crashReportSender.sendReport(
        error: StateError('Test bad state error'),
        stackTrace: null,
        getFlutterVersion: () => '[user-branch]/v1.2.3',
        command: 'crash',
      );

      // Verify that the report wasn't sent
      expect(method, null);
      expect(uri, null);

      expect(logger.traceText, isNot(contains('Crash report sent')));
    });

    testWithoutContext('can override base URL', () async {
      Uri uri;
      final MockClient mockClient = MockClient((Request request) async {
        uri = request.url;
        return Response('test-report-id', 200);
      });

      final Platform environmentPlatform = FakePlatform(
        operatingSystem: 'linux',
        environment: <String, String>{
          'HOME': '/',
          'FLUTTER_CRASH_SERVER_BASE_URL': 'https://localhost:12345/fake_server',
        },
        script: Uri(scheme: 'data'),
      );

      final CrashReportSender crashReportSender = CrashReportSender(
        client: mockClient,
        usage: testUsage,
        platform: environmentPlatform,
        logger: logger,
        operatingSystemUtils: operatingSystemUtils,
      );

      await crashReportSender.sendReport(
        error: StateError('Test bad state error'),
        stackTrace: null,
        getFlutterVersion: () => 'test-version',
        command: 'crash',
      );

      // Verify that we sent the crash report.
      expect(uri, isNotNull);
      expect(uri, Uri(
        scheme: 'https',
        host: 'localhost',
        port: 12345,
        path: '/fake_server',
        queryParameters: <String, String>{
          'product': 'Flutter_Tools',
          'version': 'test-version',
        },
      ));
    });
  });
}

class RequestInfo {
  String method;
  Uri uri;
  Map<String, String> fields;
}

class MockCrashReportSender extends MockClient {
  MockCrashReportSender(RequestInfo crashInfo) : super((Request request) async {
    MockCrashReportSender.sendCalls++;
    crashInfo.method = request.method;
    crashInfo.uri = request.url;

    // A very ad-hoc multipart request parser. Good enough for this test.
    String boundary = request.headers['Content-Type'];
    boundary = boundary.substring(boundary.indexOf('boundary=') + 9);
    crashInfo.fields = Map<String, String>.fromIterable(
      utf8.decode(request.bodyBytes)
        .split('--$boundary')
        .map<List<String>>((String part) {
        final Match nameMatch = RegExp(r'name="(.*)"').firstMatch(part);
        if (nameMatch == null) {
          return null;
        }
        final String name = nameMatch[1];
        final String value = part.split('\n').skip(2).join('\n').trim();
        return <String>[name, value];
      })
        .where((List<String> pair) => pair != null),
      key: (dynamic key) {
        final List<String> pair = key as List<String>;
        return pair[0];
      },
      value: (dynamic value) {
        final List<String> pair = value as List<String>;
        return pair[1];
      },
    );

    return Response(
      'test-report-id',
      200,
    );
  });

  static int sendCalls = 0;
}

class CrashingCrashReportSender extends MockClient {
  CrashingCrashReportSender(Object exception) : super((Request request) async {
    throw exception;
  });
}

/// A DoctorValidatorsProvider that overrides the default validators without
/// overriding the doctor.
class FakeDoctorValidatorsProvider implements DoctorValidatorsProvider {
  @override
  List<DoctorValidator> get validators => <DoctorValidator>[];

  @override
  List<Workflow> get workflows => <Workflow>[];
}
