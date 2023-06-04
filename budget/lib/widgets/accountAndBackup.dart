import 'dart:async';
import 'dart:convert';

import 'package:budget/colors.dart';
import 'package:budget/database/binary_string_conversion.dart';
import 'package:budget/database/tables.dart';
import 'package:budget/functions.dart';
import 'package:budget/main.dart';
import 'package:budget/pages/aboutPage.dart';
import 'package:budget/pages/accountsPage.dart';
import 'package:budget/pages/pastBudgetsPage.dart';
import 'package:budget/struct/databaseGlobal.dart';
import 'package:budget/struct/shareBudget.dart';
import 'package:budget/widgets/button.dart';
import 'package:budget/widgets/globalSnackBar.dart';
import 'package:budget/widgets/moreIcons.dart';
import 'package:budget/widgets/navigationFramework.dart';
import 'package:budget/widgets/navigationSidebar.dart';
import 'package:budget/widgets/openBottomSheet.dart';
import 'package:budget/widgets/openPopup.dart';
import 'package:budget/widgets/openSnackbar.dart';
import 'package:budget/widgets/popupFramework.dart';
import 'package:budget/widgets/settingsContainers.dart';
import 'package:budget/widgets/tappable.dart';
import 'package:budget/widgets/textWidgets.dart';
import 'package:budget/widgets/walletEntry.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'package:googleapis/drive/v3.dart' as drive;
import 'package:googleapis/gmail/v1.dart' as gMail;
import 'package:google_sign_in/google_sign_in.dart' as signIn;
import 'package:http/http.dart' as http;
import 'package:shimmer/shimmer.dart';
import 'package:universal_html/html.dart' as html;
import 'dart:io';

bool isSyncBackupFile(String? backupFileName) {
  if (backupFileName == null) return false;
  return backupFileName.contains("sync-");
}

bool isCurrentDeviceSyncBackupFile(String? backupFileName) {
  if (backupFileName == null) return false;
  return backupFileName == getCurrentDeviceSyncBackupFileName();
}

String getCurrentDeviceSyncBackupFileName({String? clientIDForSync}) {
  if (clientIDForSync == null) clientIDForSync = clientID;
  return "sync-" + clientIDForSync + ".sqlite";
}

String getDeviceFromSyncBackupFileName(String? backupFileName) {
  if (backupFileName == null) return "";
  return (backupFileName).replaceAll("sync-", "").split("-")[0];
}

String getCurrentDeviceName() {
  return (clientID).split("-")[0];
}

Future<DateTime> getDateOfLastSyncedWithClient(String clientIDForSync) async {
  String string =
      sharedPreferences.getString("dateOfLastSyncedWithClient") ?? "{}";
  String lastTimeSynced =
      (jsonDecode(string)[clientIDForSync] ?? "").toString();
  if (lastTimeSynced == "") return DateTime(0);
  try {
    return DateTime.parse(lastTimeSynced);
  } catch (e) {
    print("Error getting time of last sync " + e.toString());
    return DateTime(0);
  }
}

Future<bool> setDateOfLastSyncedWithClient(
    String clientIDForSync, DateTime dateTimeSynced) async {
  String string =
      sharedPreferences.getString("dateOfLastSyncedWithClient") ?? "{}";
  dynamic parsed = jsonDecode(string);
  parsed[clientIDForSync] = dateTimeSynced.toString();
  await sharedPreferences.setString(
      "dateOfLastSyncedWithClient", jsonEncode(parsed));
  return true;
}

// if changeMadeSync show loading and check if syncEveryChange is turned on
Timer? syncTimeoutTimer;
Debouncer backupDebounce = Debouncer(milliseconds: 5000);
Future<bool> createSyncBackup(
    {bool changeMadeSync = false,
    bool changeMadeSyncWaitForDebounce = true}) async {
  if (appStateSettings["currentUserEmail"] == "") return false;
  if (appStateSettings["backupSync"] == false) return false;
  if (changeMadeSync == true && appStateSettings["syncEveryChange"] == false)
    return false;
  // create the auto syncs after 10 seconds of no changes
  if (changeMadeSync == true &&
      appStateSettings["syncEveryChange"] == true &&
      changeMadeSyncWaitForDebounce == true) {
    print("Running sync debouncer");
    backupDebounce.run(() {
      createSyncBackup(
          changeMadeSync: true, changeMadeSyncWaitForDebounce: false);
    });
  }

  print("Creating sync backup");
  if (changeMadeSync) loadingIndeterminateKey.currentState!.setVisibility(true);
  if (syncTimeoutTimer?.isActive == true) {
    // openSnackbar(SnackbarMessage(title: "Please wait..."));
    if (changeMadeSync)
      loadingIndeterminateKey.currentState!.setVisibility(false);
    return false;
  } else {
    syncTimeoutTimer = Timer(Duration(milliseconds: 5000), () {
      syncTimeoutTimer!.cancel();
    });
  }

  bool hasSignedIn = false;
  if (user == null) {
    hasSignedIn = await signInGoogle(
      gMailPermissions: false,
      waitForCompletion: false,
      silentSignIn: true,
    );
  } else {
    hasSignedIn = true;
  }
  if (hasSignedIn == false) {
    if (changeMadeSync)
      loadingIndeterminateKey.currentState!.setVisibility(false);
    return false;
  }

  final authHeaders = await user!.authHeaders;
  final authenticateClient = GoogleAuthClient(authHeaders);
  drive.DriveApi driveApi = drive.DriveApi(authenticateClient);
  if (driveApi == null) {
    if (changeMadeSync)
      loadingIndeterminateKey.currentState!.setVisibility(false);
    throw "Failed to login to Google Drive";
  }

  drive.FileList fileList = await driveApi.files.list(
      spaces: 'appDataFolder', $fields: 'files(id, name, modifiedTime, size)');
  List<drive.File>? files = fileList.files;

  for (drive.File file in files ?? []) {
    if (isCurrentDeviceSyncBackupFile(file.name)) {
      try {
        await deleteBackup(driveApi, file.id ?? "");
      } catch (e) {
        print(e.toString());
      }
    }
  }
  await createBackup(null,
      silentBackup: true, deleteOldBackups: true, clientIDForSync: clientID);
  if (changeMadeSync)
    loadingIndeterminateKey.currentState!.setVisibility(false);
  return true;
}

class SyncLog {
  SyncLog({
    this.deleteLogType,
    this.updateLogType,
    required this.transactionDateTime,
    required this.pk,
    this.itemToUpdate,
  });

  DeleteLogType? deleteLogType;
  UpdateLogType? updateLogType;
  DateTime? transactionDateTime;
  int pk;
  dynamic itemToUpdate;

  @override
  String toString() {
    return "SyncLog(deleteLogType: $deleteLogType, updateLogType: $updateLogType, transactionDateTime: $transactionDateTime, pk: $pk, itemToUpdate: $itemToUpdate)";
  }
}

// load the latest backup and import any newly modified data into the db
Future<bool> syncData() async {
  if (appStateSettings["backupSync"] == false) return false;
  if (appStateSettings["currentUserEmail"] == "") return false;

  bool hasSignedIn = false;
  if (user == null) {
    hasSignedIn = await signInGoogle(
      gMailPermissions: false,
      waitForCompletion: false,
      silentSignIn: true,
    );
  } else {
    hasSignedIn = true;
  }
  if (hasSignedIn == false) {
    return false;
  }

  final authHeaders = await user!.authHeaders;
  final authenticateClient = GoogleAuthClient(authHeaders);
  drive.DriveApi driveApi = drive.DriveApi(authenticateClient);
  if (driveApi == null) {
    throw "Failed to login to Google Drive";
  }

  await createSyncBackup();

  drive.FileList fileList = await driveApi.files.list(
      spaces: 'appDataFolder', $fields: 'files(id, name, modifiedTime, size)');
  List<drive.File>? files = fileList.files;

  if (files == null) {
    throw "No backups found.";
  }

  List<drive.File> filesToDownloadSyncChanges = [];
  for (drive.File file in files) {
    if (isSyncBackupFile(file.name)) {
      filesToDownloadSyncChanges.add(file);
    }
  }

  print("LOADING SYNC DB");
  DateTime syncStarted = DateTime.now();
  List<SyncLog> syncLogs = [];
  List<drive.File> filesSyncing = [];

  for (drive.File file in filesToDownloadSyncChanges) {
    // we don't want to restore this clients backup
    if (isCurrentDeviceSyncBackupFile(file.name)) continue;

    // check if this is a new sync from this specific client
    DateTime lastSynced = await getDateOfLastSyncedWithClient(
        getDeviceFromSyncBackupFileName(file.name));

    print("COMPARING TIMES");
    print(file.modifiedTime?.toLocal());
    print(lastSynced);
    print(lastSynced != file.modifiedTime!.toLocal());
    if (file.modifiedTime == null ||
        lastSynced.isAfter(file.modifiedTime!.toLocal()) ||
        lastSynced == file.modifiedTime!.toLocal()) {
      print(
          "no need to restore backup from this client, no new backup file to pull data from");
      continue;
    }

    String? fileId = file.id;
    if (fileId == null) continue;
    print("SYNCING WITH " + (file.name ?? ""));
    filesSyncing.add(file);

    List<int> dataStore = [];
    dynamic response = await driveApi.files
        .get(fileId, downloadOptions: drive.DownloadOptions.fullMedia);
    await for (var data in response.stream) {
      dataStore.insertAll(dataStore.length, data);
    }

    if (kIsWeb) {
      final html.Storage localStorage = html.window.localStorage;
      localStorage["moor_db_str_syncdb"] =
          bin2str.encode(Uint8List.fromList(dataStore));
    } else {
      final dbFolder = await getApplicationDocumentsDirectory();
      final dbFile = File(p.join(dbFolder.path, 'syncdb.sqlite'));
      await dbFile.writeAsBytes(dataStore);
    }

    FinanceDatabase databaseSync = await constructDb('syncdb');

    try {
      List<TransactionWallet> newWallets =
          await databaseSync.getAllNewWallets(lastSynced);
      for (TransactionWallet newEntry in newWallets) {
        syncLogs.add(SyncLog(
          deleteLogType: null,
          updateLogType: UpdateLogType.TransactionWallet,
          pk: newEntry.walletPk,
          itemToUpdate: newEntry,
          transactionDateTime: newEntry.dateTimeModified,
        ));
      }
      print("NEW WALLETS");
      print(newWallets);

      List<TransactionCategory> newCategories =
          await databaseSync.getAllNewCategories(lastSynced);
      for (TransactionCategory newEntry in newCategories) {
        syncLogs.add(SyncLog(
          deleteLogType: null,
          updateLogType: UpdateLogType.TransactionCategory,
          pk: newEntry.categoryPk,
          itemToUpdate: newEntry,
          transactionDateTime: newEntry.dateTimeModified,
        ));
      }
      print("NEW CATEGORIES");
      print(newCategories);

      List<Budget> newBudgets = await databaseSync.getAllNewBudgets(lastSynced);
      for (Budget newEntry in newBudgets) {
        syncLogs.add(SyncLog(
          deleteLogType: null,
          updateLogType: UpdateLogType.Budget,
          pk: newEntry.budgetPk,
          itemToUpdate: newEntry,
          transactionDateTime: newEntry.dateTimeModified,
        ));
      }
      print("NEW BUDGETS");
      print(newBudgets);

      List<CategoryBudgetLimit> newCategoryBudgetLimits =
          await databaseSync.getAllNewCategoryBudgetLimits(lastSynced);
      for (CategoryBudgetLimit newEntry in newCategoryBudgetLimits) {
        syncLogs.add(SyncLog(
          deleteLogType: null,
          updateLogType: UpdateLogType.CategoryBudgetLimit,
          pk: newEntry.categoryLimitPk,
          itemToUpdate: newEntry,
          transactionDateTime: newEntry.dateTimeModified,
        ));
      }
      print("NEW CATEGORY LIMITS");
      print(newCategoryBudgetLimits);

      List<Transaction> newTransactions =
          await databaseSync.getAllNewTransactions(lastSynced);
      for (Transaction newEntry in newTransactions) {
        syncLogs.add(SyncLog(
          deleteLogType: null,
          updateLogType: UpdateLogType.Transaction,
          pk: newEntry.transactionPk,
          itemToUpdate: newEntry,
          transactionDateTime: newEntry.dateTimeModified,
        ));
      }
      print("NEW TRANSACTIONS");
      print(newTransactions);

      List<TransactionAssociatedTitle> newTitles =
          await databaseSync.getAllNewAssociatedTitles(lastSynced);
      for (TransactionAssociatedTitle newEntry in newTitles) {
        syncLogs.add(SyncLog(
          deleteLogType: null,
          updateLogType: UpdateLogType.TransactionAssociatedTitle,
          pk: newEntry.associatedTitlePk,
          itemToUpdate: newEntry,
          transactionDateTime: newEntry.dateTimeModified,
        ));
      }
      print("NEW TITLES");
      print(newTitles);

      for (ScannerTemplate newEntry
          in (await databaseSync.getAllNewScannerTemplates(lastSynced))) {
        syncLogs.add(SyncLog(
          deleteLogType: null,
          updateLogType: UpdateLogType.ScannerTemplate,
          pk: newEntry.scannerTemplatePk,
          itemToUpdate: newEntry,
          transactionDateTime: newEntry.dateTimeModified,
        ));
      }

      List<DeleteLog> deleteLogs =
          await databaseSync.getAllNewDeleteLogs(lastSynced);

      for (DeleteLog deleteLog in deleteLogs) {
        syncLogs.add(SyncLog(
          deleteLogType: deleteLog.type,
          updateLogType: null,
          pk: deleteLog.entryPk,
          transactionDateTime: deleteLog.dateTimeModified,
        ));
      }

      print("DELETE LOGS");
      print(deleteLogs);
    } catch (e) {
      print("SYNC FAILED");
      print(e.toString());
      openSnackbar(
        SnackbarMessage(
          title: "Sync failed",
          description: "Mismatching schema versions",
          icon: Icons.warning_amber_rounded,
        ),
      );
      filesSyncing.remove(file);
      databaseSync.close();
      return false;
    }

    databaseSync.close();
  }

  await database.processSyncLogs(syncLogs);
  for (drive.File file in filesSyncing)
    setDateOfLastSyncedWithClient(getDeviceFromSyncBackupFileName(file.name),
        file.modifiedTime?.toLocal() ?? DateTime(0));

  try {
    print("UPDATED WALLET CURRENCY");
    for (TransactionWallet wallet in await database.getAllWallets()) {
      final Map<dynamic, dynamic> cachedWalletCurrencies =
          appStateSettings["cachedWalletCurrencies"] ?? {};
      cachedWalletCurrencies[wallet.walletPk.toString()] =
          wallet.currency ?? "";
      updateSettings("cachedWalletCurrencies", cachedWalletCurrencies,
          pagesNeedingRefresh: [], updateGlobalState: false);
    }
    TransactionWallet selectedWallet =
        await database.getWalletInstance(appStateSettings["selectedWallet"]);
    updateSettings("selectedWalletCurrency", selectedWallet.currency,
        updateGlobalState: true, pagesNeedingRefresh: [0, 1, 2, 3]);
    updateSettings("selectedWalletDecimals", selectedWallet.decimals,
        updateGlobalState: true, pagesNeedingRefresh: [0, 1, 2, 3]);
  } catch (e) {
    print("Selected wallet not found: " + e.toString());
    await setPrimaryWallet((await database.getAllWallets())[0]);
  }

  updateSettings("lastSynced", syncStarted.toString(),
      pagesNeedingRefresh: [], updateGlobalState: true);
  print("DONE SYNCING");
  return true;
}

Future<bool> checkConnection() async {
  late bool isConnected;
  if (!kIsWeb) {
    try {
      final result = await InternetAddress.lookup('example.com');
      if (result.isNotEmpty && result[0].rawAddress.isNotEmpty) {
        isConnected = true;
      }
    } on SocketException catch (e) {
      print(e.toString());
      isConnected = false;
    }
  } else {
    isConnected = true;
  }
  return isConnected;
}

class GoogleAuthClient extends http.BaseClient {
  final Map<String, String> _headers;
  final http.Client _client = new http.Client();
  GoogleAuthClient(this._headers);
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    return _client.send(request..headers.addAll(_headers));
  }
}

signIn.GoogleSignInAccount? user;
signIn.GoogleSignIn? googleSignIn;

Future<bool> signInGoogle(
    {context,
    bool? waitForCompletion,
    bool? drivePermissions,
    bool? gMailPermissions,
    bool? silentSignIn,
    Function()? next}) async {
  bool isConnected = false;

  if (appStateSettings["emailScanning"] == false) gMailPermissions = false;

  try {
    if (gMailPermissions == true && !(await testIfHasGmailAccess())) {
      await signOutGoogle();
      googleSignIn = null;
      settingsPageStateKey.currentState?.refreshState();
    } else if (user == null) {
      googleSignIn = null;
      settingsPageStateKey.currentState?.refreshState();
    }
    //Check connection
    // isConnected = await checkConnection().timeout(Duration(milliseconds: 2500),
    //     onTimeout: () {
    //   throw ("There was an error checking your connection");
    // });
    // if (isConnected == false) {
    //   if (context != null) {
    //     openSnackbar(context, "Could not connect to network",
    //         backgroundColor: lightenPastel(Theme.of(context).colorScheme.error,
    //             amount: 0.6));
    //   }
    //   return false;
    // }

    if (waitForCompletion == true) openLoadingPopup(context);
    if (user == null) {
      googleSignIn = signIn.GoogleSignIn.standard(scopes: [
        ...(drivePermissions == true ? [drive.DriveApi.driveAppdataScope] : []),
        ...(gMailPermissions == true
            ? [
                gMail.GmailApi.gmailReadonlyScope,
                gMail.GmailApi
                    .gmailModifyScope //We do this so the emails can be marked read
              ]
            : [])
      ]);

      final signIn.GoogleSignInAccount? account = silentSignIn == true
          ? kIsWeb
              ? await googleSignIn?.signIn()
              // await googleSignIn?.signInSilently().then((value) async {
              //   return await googleSignIn?.signIn();
              // })
              : await googleSignIn?.signInSilently()
          : await googleSignIn?.signIn();

      if (account != null) {
        user = account;
        updateSettings("currentUserEmail", user?.email ?? "",
            updateGlobalState: false);
        accountsPageStateKey.currentState?.refreshState();
      } else {
        throw ("Login failed");
      }
    }
    if (waitForCompletion == true) Navigator.of(context).pop();
    next != null ? next() : 0;

    if (appStateSettings["hasSignedInOnce"] == false) {
      updateSettings("hasSignedInOnce", true, updateGlobalState: false);
      updateSettings("autoBackups", true, updateGlobalState: false);
    }

    return true;
  } catch (e) {
    print(e);
    if (waitForCompletion == true) Navigator.of(context).pop();
    openSnackbar(
      SnackbarMessage(
        title: "Sign-in Error",
        description: "Check your connection and try again",
        icon: Icons.error_rounded,
        onTap: () async {},
        timeout: Duration(milliseconds: 1400),
      ),
    );
    updateSettings("currentUserEmail", "", updateGlobalState: false);
    throw ("Error signing in");
  }
}

Future<bool> testIfHasGmailAccess() async {
  print("TESTING GMAIL");
  try {
    final authHeaders = await user!.authHeaders;
    final authenticateClient = GoogleAuthClient(authHeaders);
    gMail.GmailApi gmailApi = gMail.GmailApi(authenticateClient);
    gMail.ListMessagesResponse results =
        await gmailApi.users.messages.list(user!.id.toString(), maxResults: 1);
  } catch (e) {
    print("NO GMAIL");
    return false;
  }
  return true;
}

Future<bool> signOutGoogle() async {
  await googleSignIn?.signOut();
  user = null;
  updateSettings("currentUserEmail", "");
  print("Signedout");
  return true;
}

Future<void> createBackupInBackground(context) async {
  if (appStateSettings["currentUserEmail"] == "") return;
  // print(entireAppLoaded);
  print("last backup:");
  print(appStateSettings["lastBackup"]);
  //Only run this once, don't run again if the global state changes (e.g. when changing a setting)
  if (entireAppLoaded == false) {
    if (appStateSettings["autoBackups"] == true) {
      DateTime lastUpdate = DateTime.parse(appStateSettings["lastBackup"]);
      DateTime nextPlannedBackup = lastUpdate
          .add(Duration(days: appStateSettings["autoBackupsFrequency"]));
      print("next backup planned on " + nextPlannedBackup.toString());
      if (DateTime.now().millisecondsSinceEpoch >=
          nextPlannedBackup.millisecondsSinceEpoch) {
        print("auto backing up");

        bool hasSignedIn = false;
        if (user == null) {
          hasSignedIn = await signInGoogle(
              context: context,
              gMailPermissions: false,
              waitForCompletion: false,
              silentSignIn: true);
        } else {
          hasSignedIn = true;
        }
        if (hasSignedIn == false) {
          return;
        }
        await createBackup(context, silentBackup: true, deleteOldBackups: true);
      } else {
        print("backup already made today");
      }
    }
  }
  return;
}

Future<void> createBackup(
  context, {
  bool? silentBackup,
  bool deleteOldBackups = false,
  String? clientIDForSync,
}) async {
  // Backup user settings
  try {
    if (silentBackup == false || silentBackup == null) {
      loadingIndeterminateKey.currentState!.setVisibility(true);
    }
    String userSettings = sharedPreferences.getString('userSettings') ?? "";
    if (userSettings == "") throw ("No settings stored");
    await database.createOrUpdateSettings(
      AppSetting(
        settingsPk: 0,
        settingsJSON: userSettings,
        dateUpdated: DateTime.now(),
      ),
    );
    print("successfully created settings entry");
  } catch (e) {
    if (silentBackup == false || silentBackup == null) {
      Navigator.of(context).maybePop();
    }
    openSnackbar(
      SnackbarMessage(title: e.toString(), icon: Icons.error_rounded),
    );
  }

  try {
    if (deleteOldBackups)
      await deleteRecentBackups(context, appStateSettings["backupLimit"],
          silentDelete: true);
    var dbFileBytes;
    late Stream<List<int>> mediaStream;
    if (kIsWeb) {
      final html.Storage localStorage = html.window.localStorage;
      dbFileBytes = bin2str.decode(localStorage["moor_db_str_db"] ?? "");
      mediaStream = Stream.value(dbFileBytes);
    } else {
      final dbFolder = await getApplicationDocumentsDirectory();
      final dbFile = File(p.join(dbFolder.path, 'db.sqlite'));
      print("FILE SIZE:" + (dbFile.lengthSync() / 1e+6).toString());
      // Share.shareFiles([p.join(dbFolder.path, 'db.sqlite')],
      //     text: 'Database');
      // await file.readAsBytes();
      dbFileBytes = await dbFile.readAsBytes();
      mediaStream = Stream.value(List<int>.from(dbFileBytes));
    }
    final authHeaders = await user!.authHeaders;
    final authenticateClient = GoogleAuthClient(authHeaders);
    final driveApi = drive.DriveApi(authenticateClient);

    var media = new drive.Media(mediaStream, dbFileBytes.length);

    var driveFile = new drive.File();
    final timestamp =
        DateFormat("yyyy-MM-dd-hhmmss").format(DateTime.now().toUtc());
    // -$timestamp
    driveFile.name =
        "db-v$schemaVersionGlobal-${getCurrentDeviceName()}.sqlite";
    if (clientIDForSync != null)
      driveFile.name =
          getCurrentDeviceSyncBackupFileName(clientIDForSync: clientIDForSync);
    driveFile.modifiedTime = DateTime.now().toUtc();
    driveFile.parents = ["appDataFolder"];

    await driveApi.files.create(driveFile, uploadMedia: media);

    if (clientIDForSync == null)
      openSnackbar(
        SnackbarMessage(
          title: "Backup Created",
          description: driveFile.name,
          icon: Icons.backup_rounded,
        ),
      );
    if (clientIDForSync == null)
      updateSettings("lastBackup", DateTime.now().toString(),
          pagesNeedingRefresh: [], updateGlobalState: false);

    if (silentBackup == false || silentBackup == null) {
      loadingIndeterminateKey.currentState!.setVisibility(false);
    }
  } catch (e) {
    if (silentBackup == false || silentBackup == null) {
      loadingIndeterminateKey.currentState!.setVisibility(false);
    }
    openSnackbar(
      SnackbarMessage(title: e.toString(), icon: Icons.error_rounded),
    );
  }
}

Future<void> deleteRecentBackups(context, amountToKeep,
    {bool? silentDelete}) async {
  try {
    if (silentDelete == false || silentDelete == null) {
      loadingIndeterminateKey.currentState!.setVisibility(true);
    }

    final authHeaders = await user!.authHeaders;
    final authenticateClient = GoogleAuthClient(authHeaders);
    final driveApi = drive.DriveApi(authenticateClient);
    if (driveApi == null) {
      throw "Failed to login to Google Drive";
    }

    final fileList = await driveApi.files.list(
        spaces: 'appDataFolder', $fields: 'files(id, name, modifiedTime)');
    final files = fileList.files;
    if (files == null) {
      throw "No backups found.";
    }

    int index = 0;
    files.forEach((file) {
      // subtract 1 because we just made a backup
      if (index >= amountToKeep - 1) {
        // only delete excess backups that don't belong to a client sync
        if (!isSyncBackupFile(file.name)) deleteBackup(driveApi, file.id ?? "");
      }
      if (!isSyncBackupFile(file.name)) index++;
    });
    if (silentDelete == false || silentDelete == null) {
      loadingIndeterminateKey.currentState!.setVisibility(false);
    }
  } catch (e) {
    if (silentDelete == false || silentDelete == null) {
      loadingIndeterminateKey.currentState!.setVisibility(false);
    }
    openSnackbar(
      SnackbarMessage(title: e.toString(), icon: Icons.error_rounded),
    );
  }
}

Future<void> deleteBackup(drive.DriveApi driveApi, String fileId) async {
  try {
    await driveApi.files.delete(fileId);
  } catch (e) {
    openSnackbar(SnackbarMessage(title: e.toString()));
  }
}

Future<void> chooseBackup(context,
    {bool isManaging = false, bool isClientSync = false}) async {
  try {
    openBottomSheet(
      context,
      BackupManagement(
        isManaging: isManaging,
        isClientSync: isClientSync,
      ),
    );
  } catch (e) {
    Navigator.of(context).pop();
    openSnackbar(
      SnackbarMessage(title: e.toString(), icon: Icons.error_rounded),
    );
  }
}

Future<void> loadBackup(
    context, drive.DriveApi driveApi, drive.File file) async {
  try {
    openLoadingPopup(context);

    List<int> dataStore = [];
    dynamic response = await driveApi.files
        .get(file.id ?? "", downloadOptions: drive.DownloadOptions.fullMedia);
    response.stream.listen(
      (data) {
        print("Data: ${data.length}");
        dataStore.insertAll(dataStore.length, data);
      },
      onDone: () async {
        if (kIsWeb) {
          final html.Storage localStorage = html.window.localStorage;
          localStorage.clear();
          localStorage["moor_db_str_db"] =
              bin2str.encode(Uint8List.fromList(dataStore));
          // extract the db number and set it to this to run migrator
          // localStorage["moor_db_version_db"] =
          //     (file.name ?? "-").split("-")[1].replaceAll("v", "");
        } else {
          final dbFolder = await getApplicationDocumentsDirectory();
          final dbFile = File(p.join(dbFolder.path, 'db.sqlite'));
          await dbFile.writeAsBytes(dataStore);
          // we need to be able to sync with others after the restore
          await sharedPreferences.setString("dateOfLastSyncedWithClient", "{}");
          // Share.shareFiles([p.join(dbFolder.path, 'db.sqlite')],
          //     text: 'Database');
        }

        Navigator.of(context).pop();

        await updateSettings("databaseJustImported", true,
            pagesNeedingRefresh: [], updateGlobalState: false);
        print(appStateSettings);
        openSnackbar(
          SnackbarMessage(
              title: "Backup Restored",
              icon: Icons.settings_backup_restore_rounded),
        );
        restartApp(context);
      },
      onError: (error) {
        openSnackbar(
          SnackbarMessage(title: error.toString(), icon: Icons.error_rounded),
        );
      },
    );
  } catch (e) {
    Navigator.of(context).pop();
    openSnackbar(
      SnackbarMessage(title: e.toString(), icon: Icons.error_rounded),
    );
  }
}

class GoogleAccountLoginButton extends StatefulWidget {
  const GoogleAccountLoginButton({
    super.key,
    this.navigationSidebarButton = false,
    this.onTap,
    this.isButtonSelected = false,
  });
  final bool navigationSidebarButton;
  final Function? onTap;
  final bool isButtonSelected;

  @override
  State<GoogleAccountLoginButton> createState() =>
      _GoogleAccountLoginButtonState();
}

class _GoogleAccountLoginButtonState extends State<GoogleAccountLoginButton> {
  @override
  Widget build(BuildContext context) {
    Function login = () async {
      loadingIndeterminateKey.currentState!.setVisibility(true);
      try {
        await signInGoogle(
            context: context,
            waitForCompletion: false,
            drivePermissions: true,
            next: () {
              setState(() {});
              // pushRoute(context, accountsPage);
              if (widget.navigationSidebarButton) {
                if (widget.onTap != null) widget.onTap!();
              } else {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (context) => AccountsPage(),
                  ),
                );
              }
            });
        if (appStateSettings["username"] == "" && user != null) {
          updateSettings("username", user?.displayName ?? "",
              pagesNeedingRefresh: [0]);
        }
        if (user != null) {
          await syncData();
          await syncPendingQueueOnServer();
          await getCloudBudgets();
        }
      } catch (e) {
        print(e.toString());
      }
      loadingIndeterminateKey.currentState!.setVisibility(false);
    };
    if (widget.navigationSidebarButton == true) {
      return user == null
          ? NavigationSidebarButton(
              label: "Login",
              icon: MoreIcons.google,
              onTap: () async {
                login();
              },
              isSelected: false,
            )
          : NavigationSidebarButton(
              label: user!.displayName ?? "",
              icon: Icons.person_rounded,
              onTap: () async {
                if (widget.onTap != null) widget.onTap!();
              },
              isSelected: widget.isButtonSelected,
            );
    }
    return user == null
        ? SettingsContainer(
            isOutlined: true,
            onTap: () async {
              login();
            },
            title: "Login",
            icon: MoreIcons.google,
          )
        : SettingsContainerOpenPage(
            openPage: AccountsPage(),
            title: user!.displayName ?? "",
            icon: Icons.person_rounded,
            isOutlined: true,
          );
  }
}

class BackupManagement extends StatefulWidget {
  const BackupManagement({
    Key? key,
    required this.isManaging,
    required this.isClientSync,
  }) : super(key: key);

  final bool isManaging;
  final bool isClientSync;

  @override
  State<BackupManagement> createState() => _BackupManagementState();
}

class _BackupManagementState extends State<BackupManagement> {
  List<drive.File> filesState = [];
  List<int> deletedIndices = [];
  drive.DriveApi? driveApiState;
  UniqueKey dropDownKey = UniqueKey();
  bool isLoading = true;
  bool autoBackups = appStateSettings["autoBackups"];
  bool backupSync = appStateSettings["backupSync"];

  @override
  void initState() {
    super.initState();
    Future.delayed(Duration.zero, () async {
      final authHeaders = await user!.authHeaders;
      final authenticateClient = GoogleAuthClient(authHeaders);
      drive.DriveApi driveApi = drive.DriveApi(authenticateClient);
      if (driveApi == null) {
        throw "Failed to login to Google Drive";
      }

      drive.FileList fileList = await driveApi.files.list(
          spaces: 'appDataFolder', $fields: 'files(id, name, modifiedTime)');
      List<drive.File>? files = fileList.files;
      if (files == null) {
        throw "No backups found.";
      }
      setState(() {
        filesState = files;
        driveApiState = driveApi;
        isLoading = false;
      });
      bottomSheetControllerGlobal.snapToExtent(0);
    });
  }

  @override
  Widget build(BuildContext context) {
    if (widget.isClientSync) {
      if (filesState.length > 0) {
        print(appStateSettings["devicesHaveBeenSynced"]);
        filesState =
            filesState.where((file) => isSyncBackupFile(file.name)).toList();
        appStateSettings["devicesHaveBeenSynced"] = filesState.length;
      }
    } else {
      if (filesState.length > 0) {
        filesState =
            filesState.where((file) => !isSyncBackupFile(file.name)).toList();
      }
    }
    Iterable<dynamic> filesMap = filesState.asMap().entries;

    return PopupFramework(
      title: widget.isClientSync
          ? "Devices"
          : widget.isManaging
              ? "Backups"
              : "Restore a Backup",
      subtitle: widget.isClientSync
          ? "Manage the syncing of data between multiple devices. May incur extra data usage."
          : widget.isManaging
              ? null
              : "This will overwrite all previous data",
      child: Column(
        children: [
          widget.isClientSync && kIsWeb == false
              ? Row(
                  children: [
                    Expanded(
                      child: AboutInfoBox(
                        title: "Web App",
                        link: "https://budget-track.web.app/",
                        color: appStateSettings["materialYou"]
                            ? Theme.of(context).colorScheme.secondaryContainer
                            : getColor(context, "lightDarkAccentHeavyLight"),
                        padding: EdgeInsets.only(
                          left: 5,
                          right: 5,
                          bottom: 10,
                          top: 5,
                        ),
                      ),
                    ),
                  ],
                )
              : SizedBox.shrink(),
          widget.isManaging && widget.isClientSync == false
              ? Padding(
                  padding: const EdgeInsets.only(bottom: 0),
                  child: SettingsContainerSwitch(
                    onSwitched: (value) {
                      updateSettings("autoBackups", value,
                          pagesNeedingRefresh: [], updateGlobalState: false);
                      setState(() {
                        autoBackups = value;
                      });
                    },
                    initialValue: appStateSettings["autoBackups"],
                    title: "Auto Backups",
                    description: "Backup data when opened",
                    icon: Icons.backup_rounded,
                  ),
                )
              : SizedBox.shrink(),
          widget.isClientSync
              ? SettingsContainerSwitch(
                  onSwitched: (value) {
                    updateSettings("backupSync", value,
                        pagesNeedingRefresh: [], updateGlobalState: true);
                    setState(() {
                      backupSync = value;
                    });
                    Future.delayed(Duration(milliseconds: 100), () {
                      bottomSheetControllerGlobal.snapToExtent(0);
                    });
                  },
                  initialValue: appStateSettings["backupSync"],
                  title: "Sync Data",
                  description: "Sync data to other devices",
                  icon: Icons.cloud_sync_rounded,
                )
              : SizedBox.shrink(),
          widget.isClientSync
              ? Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: AnimatedSize(
                    duration: Duration(milliseconds: 800),
                    curve: Curves.easeInOutCubicEmphasized,
                    child: AnimatedSwitcher(
                      duration: Duration(milliseconds: 300),
                      child: backupSync
                          ? SettingsContainerSwitch(
                              onSwitched: (value) {
                                updateSettings("syncEveryChange", value,
                                    pagesNeedingRefresh: [],
                                    updateGlobalState: false);
                              },
                              initialValue: appStateSettings["syncEveryChange"],
                              title: "Sync on Every Change",
                              descriptionWithValue: (value) {
                                return value
                                    ? "Syncing on every change"
                                    : "Syncing on refresh/launch";
                              },
                              icon: Icons.all_inbox_rounded,
                            )
                          : Container(),
                    ),
                  ),
                )
              : SizedBox.shrink(),
          widget.isManaging && widget.isClientSync == false
              ? AnimatedSize(
                  duration: Duration(milliseconds: 800),
                  curve: Curves.easeInOutCubicEmphasized,
                  child: AnimatedSwitcher(
                    duration: Duration(milliseconds: 300),
                    child: autoBackups
                        ? Padding(
                            key: ValueKey(1),
                            padding: const EdgeInsets.only(bottom: 8),
                            child: SettingsContainerDropdown(
                              items: ["1", "2", "3", "7", "10", "14"],
                              onChanged: (value) {
                                updateSettings(
                                    "autoBackupsFrequency", int.parse(value),
                                    pagesNeedingRefresh: [],
                                    updateGlobalState: false);
                              },
                              initial: appStateSettings["autoBackupsFrequency"]
                                  .toString(),
                              title: "Backup Frequency",
                              description: "Number of days",
                              icon: Icons.event_repeat_rounded,
                            ),
                          )
                        : Container(),
                  ),
                )
              : SizedBox.shrink(),
          widget.isManaging && widget.isClientSync == false
              ? Padding(
                  padding: const EdgeInsets.only(bottom: 15),
                  child: SettingsContainerDropdown(
                    key: dropDownKey,
                    verticalPadding: 0,
                    title: "Backup Limit",
                    icon: Icons.format_list_numbered_rtl_outlined,
                    initial: appStateSettings["backupLimit"].toString(),
                    items: ["10", "15", "20", "30"],
                    onChanged: (value) {
                      if (int.parse(value) < appStateSettings["backupLimit"]) {
                        openPopup(
                          context,
                          icon: Icons.delete_rounded,
                          title: "Change Limit?",
                          description:
                              "Changing the backup limit to a smaller number will remove any past backups that are currently stored, if they exceed the limit, everytime a backup is made.",
                          onSubmit: () async {
                            updateSettings("backupLimit", int.parse(value),
                                updateGlobalState: false);
                            Navigator.pop(context);
                          },
                          onSubmitLabel: "Change",
                          onCancel: () {
                            Navigator.pop(context);
                            setState(() {
                              dropDownKey = UniqueKey();
                            });
                          },
                          onCancelLabel: "Cancel",
                        );
                      } else {
                        updateSettings("backupLimit", int.parse(value),
                            updateGlobalState: false);
                      }
                    },
                  ),
                )
              : SizedBox.shrink(),
          isLoading
              ? Column(
                  children: [
                    for (int i = 0;
                        i <
                            (widget.isClientSync
                                ? appStateSettings["devicesHaveBeenSynced"]
                                : appStateSettings["backupLimit"]);
                        i++)
                      LoadingShimmerDriveFiles(
                          isManaging: widget.isManaging, i: i),
                  ],
                )
              : SizedBox.shrink(),
          ...filesMap
              .map(
                (file) => AnimatedSize(
                  duration: Duration(milliseconds: 500),
                  curve: Curves.easeInOutCubic,
                  child: deletedIndices.contains(file.key)
                      ? Container()
                      : Padding(
                          padding: const EdgeInsets.only(bottom: 8.0),
                          child: Tappable(
                            onTap: () async {
                              if (!widget.isManaging) {
                                final result = await openPopup(
                                  context,
                                  title: "Load Backup?",
                                  description:
                                      "This will replace all your current data!",
                                  icon: Icons.warning_amber_rounded,
                                  onSubmit: () async {
                                    Navigator.pop(context, true);
                                  },
                                  onSubmitLabel: "Load",
                                  onCancelLabel: "Cancel",
                                  onCancel: () {
                                    Navigator.pop(context);
                                  },
                                );
                                if (result == true)
                                  loadBackup(
                                      context, driveApiState!, file.value);
                              }
                              // else {
                              //   await openPopup(
                              //     context,
                              //     title: "Backup Details",
                              //     description: (file.value.name ?? "") +
                              //         "\n" +
                              //         (file.value.size ?? "") +
                              //         "\n" +
                              //         (file.value.description ?? ""),
                              //     icon: Icons.warning_amber_rounded,
                              //     onSubmit: () async {
                              //       Navigator.pop(context, true);
                              //     },
                              //     onSubmitLabel: "Close",
                              //   );
                              // }
                            },
                            borderRadius: 15,
                            color: widget.isClientSync &&
                                    isCurrentDeviceSyncBackupFile(
                                        file.value.name)
                                ? Theme.of(context)
                                    .colorScheme
                                    .primary
                                    .withOpacity(0.4)
                                : appStateSettings["materialYou"]
                                    ? Theme.of(context)
                                        .colorScheme
                                        .secondaryContainer
                                    : getColor(
                                        context, "lightDarkAccentHeavyLight"),
                            child: Container(
                                padding: EdgeInsets.symmetric(
                                    horizontal: 20, vertical: 15),
                                child: Row(
                                  children: [
                                    Expanded(
                                      child: Row(
                                        children: [
                                          Icon(
                                            widget.isClientSync
                                                ? Icons.devices_rounded
                                                : Icons.description_rounded,
                                            color: Theme.of(context)
                                                .colorScheme
                                                .secondary,
                                            size: 30,
                                          ),
                                          SizedBox(
                                              width: widget.isClientSync
                                                  ? 17
                                                  : 13),
                                          Expanded(
                                            child: Column(
                                              crossAxisAlignment:
                                                  CrossAxisAlignment.start,
                                              children: [
                                                TextFont(
                                                  text: getTimeAgo(
                                                    (file.value.modifiedTime ??
                                                            DateTime.now())
                                                        .toLocal(),
                                                  ),
                                                  fontSize: 18,
                                                  fontWeight: FontWeight.bold,
                                                ),
                                                TextFont(
                                                  text: (isSyncBackupFile(
                                                          file.value.name)
                                                      ? getDeviceFromSyncBackupFileName(
                                                              file.value.name) +
                                                          " " +
                                                          "sync"
                                                      : file.value.name ??
                                                          "No name"),
                                                  fontSize: 14,
                                                  maxLines: 2,
                                                ),
                                                // isSyncBackupFile(
                                                //         file.value.name)
                                                //     ? Padding(
                                                //         padding:
                                                //             const EdgeInsets
                                                //                 .only(top: 3),
                                                //         child: TextFont(
                                                //           text:
                                                //               file.value.name ??
                                                //                   "",
                                                //           fontSize: 11,
                                                //           maxLines: 2,
                                                //         ),
                                                //       )
                                                //     : SizedBox.shrink()
                                              ],
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                    widget.isManaging
                                        ? Padding(
                                            padding: const EdgeInsets.only(
                                                left: 8.0),
                                            child: ButtonIcon(
                                                color: appStateSettings[
                                                        "materialYou"]
                                                    ? Theme.of(context)
                                                        .colorScheme
                                                        .onSecondaryContainer
                                                        .withOpacity(0.08)
                                                    : getColor(context,
                                                            "lightDarkAccentHeavy")
                                                        .withOpacity(0.7),
                                                onTap: () {
                                                  openPopup(
                                                    context,
                                                    icon: Icons.delete_rounded,
                                                    title: "Delete backup?",
                                                    description: "Backup " +
                                                        (file.value.name ??
                                                            "No name") +
                                                        " created " +
                                                        getWordedDateShortMore(
                                                            (file.value.modifiedTime ??
                                                                    DateTime
                                                                        .now())
                                                                .toLocal(),
                                                            includeTimeIfToday:
                                                                true),
                                                    onSubmit: () async {
                                                      Navigator.pop(context);
                                                      loadingIndeterminateKey
                                                          .currentState!
                                                          .setVisibility(true);
                                                      await deleteBackup(
                                                          driveApiState!,
                                                          file.value.id ?? "");
                                                      openSnackbar(
                                                        SnackbarMessage(
                                                            title:
                                                                "Deleted Backup",
                                                            description: (file
                                                                    .value
                                                                    .name ??
                                                                "No name"),
                                                            icon: Icons
                                                                .delete_rounded),
                                                      );
                                                      setState(() {
                                                        deletedIndices
                                                            .add(file.key);
                                                      });
                                                      // bottomSheetControllerGlobal
                                                      //     .snapToExtent(0);
                                                      if (widget.isClientSync)
                                                        updateSettings(
                                                            "devicesHaveBeenSynced",
                                                            appStateSettings[
                                                                    "devicesHaveBeenSynced"] -
                                                                1);
                                                      loadingIndeterminateKey
                                                          .currentState!
                                                          .setVisibility(false);
                                                    },
                                                    onSubmitLabel: "Delete",
                                                    onCancel: () {
                                                      Navigator.pop(context);
                                                    },
                                                    onCancelLabel: "Cancel",
                                                  );
                                                },
                                                icon: Icons.close_rounded),
                                          )
                                        : SizedBox.shrink(),
                                  ],
                                )),
                          ),
                        ),
                ),
              )
              .toList(),
        ],
      ),
    );
  }
}

class LoadingShimmerDriveFiles extends StatelessWidget {
  const LoadingShimmerDriveFiles({
    Key? key,
    required this.isManaging,
    required this.i,
  }) : super(key: key);

  final bool isManaging;
  final int i;

  @override
  Widget build(BuildContext context) {
    return Shimmer.fromColors(
      period:
          Duration(milliseconds: (1000 + randomDouble[i % 10] * 520).toInt()),
      baseColor: appStateSettings["materialYou"]
          ? Theme.of(context).colorScheme.secondaryContainer
          : getColor(context, "lightDarkAccentHeavyLight"),
      highlightColor: appStateSettings["materialYou"]
          ? Theme.of(context).colorScheme.secondaryContainer.withOpacity(0.2)
          : getColor(context, "lightDarkAccentHeavy").withAlpha(20),
      child: Padding(
        padding: const EdgeInsets.only(bottom: 8.0),
        child: Tappable(
          onTap: () {},
          borderRadius: 15,
          color: appStateSettings["materialYou"]
              ? Theme.of(context)
                  .colorScheme
                  .secondaryContainer
                  .withOpacity(0.5)
              : getColor(context, "lightDarkAccentHeavy").withOpacity(0.5),
          child: Container(
              padding: EdgeInsets.symmetric(horizontal: 20, vertical: 15),
              child: Row(
                children: [
                  Expanded(
                    child: Row(
                      children: [
                        Icon(
                          Icons.description_rounded,
                          color: Theme.of(context).colorScheme.secondary,
                          size: 30,
                        ),
                        SizedBox(width: 13),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Container(
                                decoration: BoxDecoration(
                                  borderRadius:
                                      BorderRadius.all(Radius.circular(5)),
                                  color: Colors.white,
                                ),
                                height: 20,
                                width: 70 + randomDouble[i % 10] * 120,
                              ),
                              SizedBox(height: 6),
                              Container(
                                decoration: BoxDecoration(
                                  borderRadius:
                                      BorderRadius.all(Radius.circular(5)),
                                  color: Colors.white,
                                ),
                                height: 14,
                                width: 90 + randomDouble[i % 10] * 120,
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  isManaging
                      ? ButtonIcon(onTap: () {}, icon: Icons.close_rounded)
                      : SizedBox.shrink(),
                ],
              )),
        ),
      ),
    );
  }
}
