// ignore_for_file: avoid_print

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:datamine_client/datamine_client.dart';

void main() {
  runApp(
    const MaterialApp(
      title: 'Data Mine Client',
      home: ClientDemo(),
    ),
  );
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

class ClientDemo extends StatefulWidget {
  const ClientDemo({Key? key}) : super(key: key);

  @override
  State createState() => ClientDemoState();
}

class ClientDemoState extends State<ClientDemo> {
  final _client = DatamineClient();
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

  Widget _buildBody() {
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Data Mine Client'),
      ),
      body: ConstrainedBox(
        constraints: const BoxConstraints.expand(),
        child: _buildBody(),
      ),
    );
  }
}
