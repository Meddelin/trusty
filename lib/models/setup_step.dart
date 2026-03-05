import 'package:flutter/material.dart';
import '../utils/localization_helper.dart';

/// Steps of the server installation process
enum SetupStep {
  idle,
  connecting,
  checkingSystem,
  installing,
  configuringServer,
  obtainingCertificate,
  startingService,
  verifying,
  completed,
  failed,
}

extension SetupStepExtension on SetupStep {
  /// Get display text
  String get displayText {
    switch (this) {
      case SetupStep.idle:
        return L10n.tr.setupStepIdle;
      case SetupStep.connecting:
        return L10n.tr.setupStepConnecting;
      case SetupStep.checkingSystem:
        return L10n.tr.setupStepCheckingSystem;
      case SetupStep.installing:
        return L10n.tr.setupStepInstalling;
      case SetupStep.configuringServer:
        return L10n.tr.setupStepConfiguringServer;
      case SetupStep.obtainingCertificate:
        return L10n.tr.setupStepObtainingCertificate;
      case SetupStep.startingService:
        return L10n.tr.setupStepStartingService;
      case SetupStep.verifying:
        return L10n.tr.setupStepVerifying;
      case SetupStep.completed:
        return L10n.tr.setupStepCompleted;
      case SetupStep.failed:
        return L10n.tr.setupStepFailed;
    }
  }

  /// Get step color
  Color get color {
    switch (this) {
      case SetupStep.idle:
        return Colors.grey;
      case SetupStep.connecting:
      case SetupStep.checkingSystem:
      case SetupStep.installing:
      case SetupStep.configuringServer:
      case SetupStep.obtainingCertificate:
      case SetupStep.startingService:
      case SetupStep.verifying:
        return Colors.orange;
      case SetupStep.completed:
        return Colors.green;
      case SetupStep.failed:
        return Colors.red;
    }
  }

  /// Get step icon
  IconData get icon {
    switch (this) {
      case SetupStep.idle:
        return Icons.cloud_upload_outlined;
      case SetupStep.connecting:
        return Icons.lan;
      case SetupStep.checkingSystem:
        return Icons.search;
      case SetupStep.installing:
        return Icons.download;
      case SetupStep.configuringServer:
        return Icons.settings;
      case SetupStep.obtainingCertificate:
        return Icons.security;
      case SetupStep.startingService:
        return Icons.play_circle;
      case SetupStep.verifying:
        return Icons.verified;
      case SetupStep.completed:
        return Icons.check_circle;
      case SetupStep.failed:
        return Icons.error;
    }
  }

  /// Whether the step is in progress
  bool get isInProgress {
    return this != SetupStep.idle &&
        this != SetupStep.completed &&
        this != SetupStep.failed;
  }

  /// Step index for progress tracking (0-based, -1 for idle/failed)
  int get stepIndex {
    switch (this) {
      case SetupStep.idle:
      case SetupStep.failed:
        return -1;
      case SetupStep.connecting:
        return 0;
      case SetupStep.checkingSystem:
        return 1;
      case SetupStep.installing:
        return 2;
      case SetupStep.configuringServer:
        return 3;
      case SetupStep.obtainingCertificate:
        return 4;
      case SetupStep.startingService:
        return 5;
      case SetupStep.verifying:
        return 6;
      case SetupStep.completed:
        return 7;
    }
  }
}
