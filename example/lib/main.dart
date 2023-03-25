// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:io';

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

  Widget _buildLayout(BuildContext context, BoxConstraints contraints) {
    final authHeight = contraints.maxHeight / 3;
    final fileHeight = contraints.maxHeight - authHeight;
    return Column(
      children: [
        ConstrainedBox(
          constraints: BoxConstraints.expand(height: authHeight),
          child: ClientAuth(),
        ),
        ConstrainedBox(
          constraints: BoxConstraints.expand(height: fileHeight),
          child: ClientFiles(),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Data Mine Client'),
        actions: [LogLevelDropdown()],
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
  const ClientAuth({Key? key}) : super(key: key);

  @override
  State createState() => ClientAuthState();
}

class ClientAuthState extends State<ClientAuth> {
  UserInfo? _currentUser;

  @override
  void initState() {
    super.initState();
    _client.onUserChanged.listen((UserInfo? user) {
      setState(() {
        _currentUser = user;
      });
    });
  }

  Future<void> _handleSignIn() async {
    try {
      await _client.signIn();
    } catch (error) {
      print(error);
    }
  }

  Future<void> _handleSignOut() => _client.signOut();

  @override
  Widget build(BuildContext context) {
    final user = _currentUser;

    if (user == null) {
      return Column(
        mainAxisAlignment: MainAxisAlignment.spaceAround,
        children: <Widget>[
          const Text('You are not currently signed in.'),
          ElevatedButton(
            onPressed: _handleSignIn,
            child: const Text('SIGN IN'),
          ),
        ],
      );
    }

    final String displayName = user.toString();
    final String? photoUrl = user.photoUrl;

    final CircleAvatar avatar;
    if (photoUrl != null) {
      avatar = CircleAvatar(
        radius: 14,
        foregroundImage: NetworkImage(photoUrl),
      );
    } else {
      avatar = CircleAvatar(
        backgroundColor: Colors.brown.shade800,
        child: Text(initials(displayName)),
      );
    }

    return Column(
      mainAxisAlignment: MainAxisAlignment.spaceAround,
      children: <Widget>[
        ListTile(leading: avatar, title: Text(displayName)),
        ElevatedButton(
          onPressed: _handleSignOut,
          child: const Text('SIGN OUT'),
        ),
      ],
    );
  }
}

class ClientFiles extends StatefulWidget {
  const ClientFiles({super.key});

  @override
  State createState() => ClientFilesState();
}

class ClientFilesState extends State<ClientFiles> {
  final List<String> uploads = [];
  final Map<String, String> dynamics = {};
  List<String> curFiles = [];

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

    final hash = await _client.storeFile(File(file.path!));
    setState(() {
      uploads.add("${shorten(hash)} -> ${shorten(file.name)}");
    });
  }

  void _handleDynamicUpload() async {
    final result = await FilePicker.platform.pickFiles(allowMultiple: false);
    if (result == null) {
      return;
    }
    final file = result.files.single;
    if (file.path == null) {
      print(file);
      return;
    }

    final fileId = await _client.storeDynamicFile(File(file.path!));
    setState(() {
      uploads.add("${shorten(fileId)} -> ${shorten(file.name)}");
      dynamics[fileId] = file.path!;
    });
  }

  void _handleList() async {
    final fileList = await _client.listFiles();
    setState(() => curFiles = fileList);
  }

  void Function() _updateHandler(String name) {
    return () async {
      try {
        final filepath = dynamics[name]!;
        await _client.updateDynamicFile(File(filepath));
      } catch (err) {
        print(err);
      }
    };
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
        print("hash for file $name = $b64Hash");
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
        ElevatedButton(
          onPressed: _handleUpload,
          child: const Text('UPLOAD FILE'),
        ),
        ElevatedButton(
          onPressed: _handleDynamicUpload,
          child: const Text('UPLOAD Dynamic FILE'),
        ),
        Padding(padding: EdgeInsets.all(20)),
        for (String name in dynamics.keys)
          ElevatedButton(onPressed: _updateHandler(name), child: Text(name)),
        Padding(padding: EdgeInsets.all(20)),
        ElevatedButton(
          onPressed: _handleList,
          child: const Text('LIST FILES'),
        ),
        for (String name in curFiles)
          ElevatedButton(
              onPressed: _downloadHandler(name), child: Text(shorten(name))),
      ],
    ));
  }
}
