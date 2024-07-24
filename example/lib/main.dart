// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:hash/hash.dart' as hash;
import 'package:logging/logging.dart';

import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:datamine_client/datamine_client.dart';

final _client = DatamineClient();

void main() {
  hierarchicalLoggingEnabled = true;
  Logger.root.level = Level.ALL;
  Logger.root.onRecord.listen((record) {
    String line =
        '${record.level.name}:${record.loggerName}:${record.time}: ${record.message}';
    if (record.error != null) {
      line += record.error.toString();
    }
    print(line);
  });

  runApp(
    const MaterialApp(
      title: 'Data Mine Client',
      home: HomePage(),
    ),
  );
}

class HomePage extends StatelessWidget {
  const HomePage({super.key});

  Widget _fittedSection(Widget child, double height, double width) {
    return ConstrainedBox(
      constraints: BoxConstraints.tightFor(height: height),
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: ConstrainedBox(
          constraints: BoxConstraints.tightFor(width: width),
          child: child,
        ),
      ),
    );
  }

  Widget _buildLayout(BuildContext context, BoxConstraints constraints) {
    final authHeight = min(constraints.maxHeight / 3, 110.0);

    return Column(
      children: [
        _fittedSection(const ClientAuth(), authHeight, constraints.maxWidth),
        const Divider(height: 15, thickness: 5),
        const Expanded(child: ClientFiles()),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Data Mine Client'),
        actions: const [LogLevelDropdown()],
      ),
      body: LayoutBuilder(builder: _buildLayout),
    );
  }
}

String initials(String input) {
  String result = "";
  List<String> words = input.split(" ");
  for (var element in words) {
    if (element.trim().isNotEmpty && result.length < 2) {
      result += element[0].trim();
    }
  }

  return result.trim().toUpperCase();
}

String shorten(String full) {
  final len = full.length;
  if (len < 18) {
    return full;
  }
  return "${full.substring(0, 10)}...${full.substring(len - 5)}";
}

class LogLevelDropdown extends StatefulWidget {
  const LogLevelDropdown({super.key});

  @override
  State<LogLevelDropdown> createState() => _LogLevelDropdown();
}

class _LogLevelDropdown extends State<LogLevelDropdown> {
  Level current = Level.ALL;

  @override
  Widget build(BuildContext context) {
    return DropdownButton<String>(
      value: current.name,
      onChanged: (String? value) {
        setState(() {
          current = Level.LEVELS.firstWhere((l) => l.name == value!);
          Logger.root.children["datamine_client"]?.level = current;
        });
      },
      items: Level.LEVELS.map<DropdownMenuItem<String>>((Level lvl) {
        return DropdownMenuItem<String>(
          value: lvl.name,
          child: Text(lvl.name),
        );
      }).toList(),
    );
  }
}

class ClientAuth extends StatefulWidget {
  const ClientAuth({super.key});

  @override
  State createState() => ClientAuthState();
}

class ClientAuthState extends State<ClientAuth> {
  UserInfo? _currentUser;
  bool offline = true;

  @override
  void initState() {
    super.initState();
    setUser(UserInfo? user) {
      setState(() {
        _currentUser = user;
        offline = _client.offline;
      });
    }
    _client.currentUser.then(setUser);
    _client.onUserChanged.listen(setUser);
  }

  void _handleSignIn(BuildContext context) {
    _client.signIn().catchError((error) async {
      final conflict = (error as OwnershipException).currentOwner;
      final force = await showDialog(
        context: context,
        builder: (context) {
          return _buildConfirm(context, conflict);
        },
      );
      if (force) return _client.signIn(force: true);
    }, test: (err) => err is OwnershipException).catchError((error) {
      Logger.root.severe("failed signing in: ", error);
    });
  }

  Widget _buildConfirm(BuildContext context, DeviceInfo conflict) {
    return SimpleDialog(
      title: const Text("Claim Write Access"),
      children: [
        Text("Data Mine is currently being managed by ${conflict.deviceName}. "
            "You will not be able to upload anything from this device.\n\n"
            "Would you like to transfer management to this device? "
            "Any pending updates from your other device might be lost"),
        SimpleDialogOption(
          child: const Text("Claim Write Access"),
          onPressed: () => Navigator.pop(context, true),
        ),
        SimpleDialogOption(
          child: const Text("Cancel"),
          onPressed: () => Navigator.pop(context, false),
        ),
      ],
    );
  }

  Future<void> _handleSignOut() => _client.signOut();

  @override
  Widget build(BuildContext context) {
    final Widget userDisplay, action;

    final user = _currentUser;
    if (user == null) {
      userDisplay = const Text("Sign in to select account");
    } else {
      final String? photoPath = user.photoPath;
      final CircleAvatar avatar;
      if (photoPath != null) {
        avatar = CircleAvatar(
          radius: 14,
          foregroundImage: FileImage(File(photoPath)),
        );
      } else {
        avatar = CircleAvatar(
          backgroundColor: Colors.green,
          child: Text(initials(user.displayName ?? "")),
        );
      }
      userDisplay = ListTile(leading: avatar, title: Text(user.toString()));
    }

    if (offline) {
      action = ElevatedButton(
        onPressed: () => _handleSignIn(context),
        child: const Text("SIGN IN"),
      );
    } else {
      action = ElevatedButton(
        onPressed: _handleSignOut,
        child: const Text("SIGN OUT"),
      );
    }

    return Column(
      mainAxisAlignment: MainAxisAlignment.spaceAround,
      children: <Widget>[userDisplay, action],
    );
  }
}

class ClientFiles extends StatefulWidget {
  const ClientFiles({super.key});

  @override
  State createState() => ClientFilesState();
}

class ClientFilesState extends State<ClientFiles> {
  final idCtrl = TextEditingController();
  final List<String> uploads = [];
  List<String> curFiles = [];

  @override
  void dispose() {
    // Clean up the controller when the widget is disposed.
    idCtrl.dispose();
    super.dispose();
  }

  void _handleUpload() async {
    final result = await FilePicker.platform.pickFiles(allowMultiple: false);
    if (result == null) {
      return;
    }
    final file = result.files.single;
    if (file.path == null) {
      print(file);
      return;
    }

    final inputId = idCtrl.text != "" ? idCtrl.text : null;
    idCtrl.clear();

    final id = await _client.storeFile(File(file.path!), id: inputId);
    setState(() {
      uploads.add("${shorten(id)} -> ${shorten(file.name)}");
      if (uploads.length > 5) {
        uploads.removeRange(0, uploads.length - 5);
      }
    });
  }

  void _handleList() async {
    final fileList = await _client.listFiles();
    fileList.sort();
    setState(() => curFiles = fileList);
  }

  void Function() _downloadHandler(String name) {
    return () async {
      try {
        final file = await _client.getFile(name);
        final rawHash = hash.SHA256();
        await for (List<int> chunk in file.openRead()) {
          rawHash.update(chunk);
        }
        final b64Hash = base64UrlEncode(rawHash.digest());
        print("hash for file '$name' = '$b64Hash'");
      } catch (err) {
        print(err);
      }
    };
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
        child: Column(
      // mainAxisAlignment: MainAxisAlignment.spaceAround,
      children: [
        Column(children: [for (String item in uploads) Text(item)]),
        Row(children: [
          Expanded(child: TextField(controller: idCtrl)),
          ElevatedButton(
            onPressed: _handleUpload,
            child: const Text('UPLOAD FILE'),
          ),
        ]),
        const Padding(padding: EdgeInsets.all(20)),
        ElevatedButton(
          onPressed: _handleList,
          child: const Text('LIST FILES'),
        ),
        for (String name in curFiles)
          ElevatedButton(
            onPressed: _downloadHandler(name),
            child: Text(shorten(name)),
          ),
      ],
    ));
  }
}
