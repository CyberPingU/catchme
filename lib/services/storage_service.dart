import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:path_provider/path_provider.dart';
import '../models/user_profile.dart';
import '../models/contact.dart';
import '../models/chat_message.dart';

class StorageService {
  static const String _profileKey = 'user_profile';
  static const String _blockedUsersKey = 'blocked_users';
  static const String _contactsKey = 'contacts';
  static const String _groupsKey = 'contact_groups';

  static Future<void>? _chatWriteQueue;
  static Future<void>? _contactWriteQueue;

  Future<void> saveProfile(UserProfile profile) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_profileKey, jsonEncode(profile.toJson()));
  }

  Future<UserProfile?> loadProfile() async {
    final prefs = await SharedPreferences.getInstance();
    final profileJson = prefs.getString(_profileKey);
    if (profileJson == null) return null;
    return UserProfile.fromJson(jsonDecode(profileJson));
  }

  Future<void> addBlockedUser(String endpointId) async {
    final prefs = await SharedPreferences.getInstance();
    final blocked = await getBlockedUsers();
    blocked.add(endpointId);
    await prefs.setStringList(_blockedUsersKey, blocked.toList());
  }

  Future<void> removeBlockedUser(String endpointId) async {
    final prefs = await SharedPreferences.getInstance();
    final blocked = await getBlockedUsers();
    blocked.remove(endpointId);
    await prefs.setStringList(_blockedUsersKey, blocked.toList());
  }

  Future<Set<String>> getBlockedUsers() async {
    final prefs = await SharedPreferences.getInstance();
    return (prefs.getStringList(_blockedUsersKey) ?? []).toSet();
  }

  Future<bool> isUserBlocked(String endpointId) async {
    final blocked = await getBlockedUsers();
    return blocked.contains(endpointId);
  }

  // Gestione contatti
  Future<void> saveContact(Contact contact) async {
    final completer = Completer<void>();
    final previous = _contactWriteQueue;
    _contactWriteQueue = completer.future;

    if (previous != null) {
      await previous;
    }

    try {
      final prefs = await SharedPreferences.getInstance();
      final contacts = await getContacts();
      
      // Rimuovi il contatto esistente con lo stesso ID se presente
      contacts.removeWhere((c) => c.id == contact.id);
      
      // Aggiungi il nuovo contatto
      contacts.add(contact);
      
      // Salva la lista aggiornata
      final contactsJson = contacts.map((c) => jsonEncode(c.toJson())).toList();
      await prefs.setStringList(_contactsKey, contactsJson);
    } finally {
      completer.complete();
    }
  }

  Future<List<Contact>> getContacts() async {
    final prefs = await SharedPreferences.getInstance();
    final contactsJson = prefs.getStringList(_contactsKey) ?? [];
    
    return contactsJson
        .map((json) => Contact.fromJson(jsonDecode(json)))
        .toList();
  }

  Future<Contact?> getContactByPublicKey(String publicKey) async {
    final contacts = await getContacts();
    try {
      return contacts.firstWhere((c) => c.publicKey == publicKey);
    } catch (e) {
      return null;
    }
  }

  Future<Contact?> getContactById(String id) async {
    final contacts = await getContacts();
    try {
      return contacts.firstWhere((c) => c.id == id);
    } catch (e) {
      return null;
    }
  }

  Future<void> removeContact(String id) async {
    final prefs = await SharedPreferences.getInstance();
    final contacts = await getContacts();
    
    contacts.removeWhere((c) => c.id == id);
    
    final contactsJson = contacts.map((c) => jsonEncode(c.toJson())).toList();
    await prefs.setStringList(_contactsKey, contactsJson);
  }

  Future<void> updateContactBlockStatus(String id, bool isBlocked) async {
    final contacts = await getContacts();
    final contactIndex = contacts.indexWhere((c) => c.id == id);
    
    if (contactIndex != -1) {
      final updatedContact = contacts[contactIndex].copyWith(isBlocked: isBlocked);
      contacts[contactIndex] = updatedContact;
      
      final prefs = await SharedPreferences.getInstance();
      final contactsJson = contacts.map((c) => jsonEncode(c.toJson())).toList();
      await prefs.setStringList(_contactsKey, contactsJson);
    }
  }

  Future<bool> isContactSaved(String publicKey) async {
    final contact = await getContactByPublicKey(publicKey);
    return contact != null;
  }

  // Gestione cronologia messaggi
  String _getChatHistoryKey(String contactId) => 'chat_history_$contactId';

  Future<void> saveChatMessage(String contactId, ChatMessage message) async {
    final completer = Completer<void>();
    final previous = _chatWriteQueue;
    _chatWriteQueue = completer.future;

    if (previous != null) {
      await previous;
    }

    try {
      final prefs = await SharedPreferences.getInstance();
      final key = _getChatHistoryKey(contactId);
      
      // Carica la cronologia esistente
      final history = await getChatHistory(contactId);
      
      // Evita duplicati nella cronologia locale
      if (history.any((m) => m.id == message.id)) {
        return;
      }
      
      // Aggiungi il nuovo messaggio
      history.add(message);
      
      // Salva la cronologia aggiornata
      final messagesJson = history.map((m) => jsonEncode(m.toJson())).toList();
      await prefs.setStringList(key, messagesJson);
    } finally {
      completer.complete();
    }
  }

  Future<List<ChatMessage>> getChatHistory(String contactId) async {
    final prefs = await SharedPreferences.getInstance();
    final key = _getChatHistoryKey(contactId);
    final messagesJson = prefs.getStringList(key) ?? [];
    
    return messagesJson
        .map((json) => ChatMessage.fromJson(jsonDecode(json)))
        .toList();
  }

  Future<void> updateChatMessageStatus(String contactId, String messageId, MessageStatus status) async {
    final completer = Completer<void>();
    final previous = _chatWriteQueue;
    _chatWriteQueue = completer.future;

    if (previous != null) {
      await previous;
    }

    try {
      final prefs = await SharedPreferences.getInstance();
      final key = _getChatHistoryKey(contactId);
      final history = await getChatHistory(contactId);
      
      final index = history.indexWhere((m) => m.id == messageId);
      if (index != -1) {
        history[index] = history[index].copyWith(status: status);
        final messagesJson = history.map((m) => jsonEncode(m.toJson())).toList();
        await prefs.setStringList(key, messagesJson);
      }
    } finally {
      completer.complete();
    }
  }

  Future<void> deleteChatHistory(String contactId) async {
    final prefs = await SharedPreferences.getInstance();
    final key = _getChatHistoryKey(contactId);
    await prefs.remove(key);
  }

  // Gestione foto profilo contatti
  Future<String> saveContactPhoto(String contactId, List<int> photoBytes) async {
    final directory = await getApplicationDocumentsDirectory();
    final photosDir = Directory('${directory.path}/contact_photos');
    
    // Crea la directory se non esiste
    if (!await photosDir.exists()) {
      await photosDir.create(recursive: true);
    }
    
    final filePath = '${photosDir.path}/$contactId.jpg';
    final file = File(filePath);
    await file.writeAsBytes(photoBytes);
    
    return filePath;
  }

  Future<File?> getContactPhoto(String contactId) async {
    final directory = await getApplicationDocumentsDirectory();
    final filePath = '${directory.path}/contact_photos/$contactId.jpg';
    final file = File(filePath);
    
    if (await file.exists()) {
      return file;
    }
    return null;
  }

  Future<void> deleteContactPhoto(String contactId) async {
    final directory = await getApplicationDocumentsDirectory();
    final filePath = '${directory.path}/contact_photos/$contactId.jpg';
    final file = File(filePath);
    
    if (await file.exists()) {
      await file.delete();
    }
  }

  // Gestione allegati e file multimediali della chat
  Future<String> saveChatAttachment(String filename, List<int> bytes) async {
    final directory = await getApplicationDocumentsDirectory();
    final attachmentsDir = Directory('${directory.path}/chat_attachments');
    
    // Crea la directory se non esiste
    if (!await attachmentsDir.exists()) {
      await attachmentsDir.create(recursive: true);
    }
    
    // Evita sovrascritture usando un timestamp se il file esiste già
    String filePath = '${attachmentsDir.path}/$filename';
    File file = File(filePath);
    if (await file.exists()) {
      final nameParts = filename.split('.');
      final ext = nameParts.length > 1 ? nameParts.last : '';
      final baseName = nameParts.length > 1 ? nameParts.sublist(0, nameParts.length - 1).join('.') : filename;
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      filePath = '${attachmentsDir.path}/${baseName}_$timestamp${ext.isNotEmpty ? '.$ext' : ''}';
      file = File(filePath);
    }
    
    await file.writeAsBytes(bytes);
    return filePath;
  }

  Future<void> updateContactAvatar(String contactId, String avatarPath) async {
    final contacts = await getContacts();
    final contactIndex = contacts.indexWhere((c) => c.id == contactId);
    
    if (contactIndex != -1) {
      final updatedContact = contacts[contactIndex].copyWith(avatarPath: avatarPath);
      await saveContact(updatedContact);
    }
  }

  Future<List<String>> getContactGroups() async {
    final prefs = await SharedPreferences.getInstance();
    final groups = prefs.getStringList(_groupsKey);
    if (groups == null || groups.isEmpty) {
      return ['Nuovi'];
    }
    final list = List<String>.from(groups);
    // Assicura che "Nuovi" sia sempre al primo posto
    if (!list.contains('Nuovi')) {
      list.insert(0, 'Nuovi');
    } else {
      list.remove('Nuovi');
      list.insert(0, 'Nuovi');
    }
    return list;
  }

  Future<void> saveContactGroups(List<String> groups) async {
    final prefs = await SharedPreferences.getInstance();
    final cleanGroups = groups.map((g) => g.trim()).where((g) => g.isNotEmpty).toList();
    if (!cleanGroups.contains('Nuovi')) {
      cleanGroups.insert(0, 'Nuovi');
    } else {
      cleanGroups.remove('Nuovi');
      cleanGroups.insert(0, 'Nuovi');
    }
    await prefs.setStringList(_groupsKey, cleanGroups);
  }
}
