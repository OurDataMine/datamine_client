// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:datamine_client/datamine_client.dart';

final _client = DatamineClient();

void main() {
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
      ),
      body: LayoutBuilder(builder: _buildLayout),
    );
  }
}

String initials(input) {
  String result = "";
  List<String> words = input.split(" ");
  for (var element in words) {
    if (element.trim().isNotEmpty && result.length < 2) {
      result += element[0].trim();
    }
  }

  return result.trim().toUpperCase();
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

    final String displayName = user.displayName ?? '';
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
      uploads.add("$hash -> ${file.name}");
    });
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      // mainAxisAlignment: MainAxisAlignment.spaceAround,
      children: [
        ElevatedButton(
          onPressed: _handleUpload,
          child: const Text('UPLOAD FILE'),
        ),
        Column(children: [for (String item in uploads) Text(item)]),
      ],
    );
  }
}
