import 'dart:io';
import 'package:flutter/material.dart';
import '../models/contact.dart';
import '../models/nearby_user.dart';
import '../services/storage_service.dart';
import '../services/proximity_service.dart';
import '../services/crypto_service.dart';
import 'chat_screen.dart';
import '../widgets/user_profile_card.dart';

class ContactsScreen extends StatefulWidget {
  final int currentTab;
  
  const ContactsScreen({super.key, required this.currentTab});

  @override
  State<ContactsScreen> createState() => _ContactsScreenState();
}

class _ContactsScreenState extends State<ContactsScreen> {
  final _storageService = StorageService();
  final _bluetoothService = ProximityService();
  final _cryptoService = CryptoService();

  List<Contact> _contacts = [];
  List<NearbyUser> _nearbyUsers = [];
  List<String> _groups = ['Nuovi'];
  String? _draggedOverGroup;

  @override
  void initState() {
    super.initState();
    _loadContacts();
    _listenToNearbyUsers();
  }

  @override
  void didUpdateWidget(ContactsScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Ricarica i contatti quando si torna alla tab Contatti
    if (widget.currentTab == 1 && oldWidget.currentTab != 1) {
      _loadContacts();
    }
  }

  Future<void> _loadContacts() async {
    final contacts = await _storageService.getContacts();
    final groups = await _storageService.getContactGroups();
    setState(() {
      _contacts = contacts;
      _groups = groups;
    });
  }

  void _listenToNearbyUsers() {
    _bluetoothService.discoveredUsers.listen((users) {
      setState(() => _nearbyUsers = users);
    });
  }

  Color _getStatusColor(Contact contact) {
    final isOnline = _bluetoothService.connectedEndpoints.contains(contact.id);
    if (!isOnline) {
      return Colors.grey;
    }
    
    // Se è online, controlliamo se è vicino ed occupato
    final nearbyUser = _getNearbyUser(contact);
    if (nearbyUser != null && nearbyUser.status.toLowerCase().contains('occupato')) {
      return Colors.red;
    }
    
    return Colors.green;
  }

  NearbyUser? _getNearbyUser(Contact contact) {
    try {
      return _nearbyUsers.firstWhere(
        (user) {
          // Sotto WebSockets, endpointId coincide con l'ID permanente del contatto (publicKeyHash)
          if (user.endpointId == contact.id) return true;
          
          // Fallback per Bluetooth locale
          if (user.publicKey != null && user.publicKey!.isNotEmpty && contact.publicKey.isNotEmpty) {
            final userId = _cryptoService.getPublicKeyHash(user.publicKey!);
            final contactId = _cryptoService.getPublicKeyHash(contact.publicKey);
            return userId == contactId;
          }
          return false;
        },
      );
    } catch (e) {
      return null;
    }
  }

  Future<void> _openChat(Contact contact) async {
    final nearbyUser = _getNearbyUser(contact);
    
    if (nearbyUser != null) {
      // Utente rilevato nelle vicinanze
      if (!nearbyUser.isConnected) {
        // Non ancora connesso: avvia la connessione in background (non-blocking)
        _bluetoothService.requestConnection(nearbyUser.endpointId);
      }
      
      // Apri chat immediatamente senza attendere la connessione
      if (mounted) {
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => ChatScreen(
              user: nearbyUser,
              bluetoothService: _bluetoothService,
            ),
          ),
        );
      }
    } else {
      // Utente offline: apri chat in modalità solo lettura (cronologia)
      final offlineUser = NearbyUser(
        endpointId: contact.id,
        nickname: contact.nickname,
        status: 'Offline',
        isConnected: false,
        publicKey: contact.publicKey,
        isVerified: true,
      );
      
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => ChatScreen(
            user: offlineUser,
            bluetoothService: _bluetoothService,
          ),
        ),
      );
    }
  }


  Future<void> _addNewGroup() async {
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Crea Nuovo Gruppo'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(
            hintText: 'Nome del gruppo',
            border: OutlineInputBorder(),
          ),
          autofocus: true,
          textCapitalization: TextCapitalization.sentences,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Annulla'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('Crea'),
          ),
        ],
      ),
    );

    if (name != null && name.isNotEmpty) {
      if (_groups.contains(name)) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Questo gruppo esiste già!')),
          );
        }
        return;
      }
      final updatedGroups = List<String>.from(_groups)..add(name);
      await _storageService.saveContactGroups(updatedGroups);
      await _loadContacts();
    }
  }

  Future<void> _deleteGroup(String groupName) async {
    if (groupName == 'Nuovi') return; // Non cancellabile
    
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Elimina Gruppo'),
        content: Text('Vuoi eliminare il gruppo "$groupName"? I contatti in esso contenuti verranno reinseriti nel gruppo "Nuovi".'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Annulla'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Elimina', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      // 1. Sposta tutti i contatti di quel gruppo in "Nuovi"
      final updatedContacts = _contacts.map((c) {
        if (c.group == groupName) {
          return c.copyWith(group: 'Nuovi');
        }
        return c;
      }).toList();

      // Salva ciascuno dei contatti aggiornati
      for (final contact in updatedContacts) {
        if (contact.group == 'Nuovi') {
          await _storageService.saveContact(contact);
        }
      }

      // 2. Rimuovi il gruppo dall'elenco
      final updatedGroups = List<String>.from(_groups)..remove(groupName);
      await _storageService.saveContactGroups(updatedGroups);
      
      await _loadContacts();
    }
  }

  Future<void> _moveContactToGroup(Contact contact, String targetGroup) async {
    if (contact.group == targetGroup) return;
    
    final updatedContact = contact.copyWith(group: targetGroup);
    await _storageService.saveContact(updatedContact);
    
    // Ricarica per aggiornare le liste
    await _loadContacts();
    
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('${contact.nickname} spostato in "$targetGroup"'),
          duration: const Duration(seconds: 1),
        ),
      );
    }
  }
 
  void _showUserProfile(Contact contact) {
    final nearbyUser = _getNearbyUser(contact) ?? NearbyUser(
      endpointId: contact.id,
      nickname: contact.nickname,
      status: 'Offline',
      isConnected: false,
      publicKey: contact.publicKey,
      isVerified: true,
      birthDate: contact.birthDate,
      gender: contact.gender,
      bio: contact.bio,
    );
    
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => UserProfileCard(
        user: nearbyUser,
        initialAvatarPath: contact.avatarPath,
        bluetoothService: _bluetoothService,
        onActionDone: () {
          _loadContacts();
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Contatti'),
        actions: [
          IconButton(
            icon: const Icon(Icons.create_new_folder),
            tooltip: 'Nuovo Gruppo',
            onPressed: _addNewGroup,
          ),
        ],
      ),
      body: (_contacts.isEmpty && _groups.length <= 1)
          ? RefreshIndicator(
              onRefresh: _loadContacts,
              child: SingleChildScrollView(
                physics: const AlwaysScrollableScrollPhysics(),
                child: SizedBox(
                  height: MediaQuery.of(context).size.height - 200,
                  child: const Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.contacts_outlined, size: 64, color: Colors.grey),
                        SizedBox(height: 16),
                        Text(
                          'Nessun contatto salvato',
                          style: TextStyle(fontSize: 18, color: Colors.grey),
                        ),
                        SizedBox(height: 8),
                        Text(
                          'Vai al Radar per trovare nuovi utenti',
                          style: TextStyle(color: Colors.grey),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            )
          : RefreshIndicator(
              onRefresh: _loadContacts,
              child: ListView.builder(
                padding: const EdgeInsets.all(16),
                itemCount: _groups.length,
                itemBuilder: (context, index) {
                  final groupName = _groups[index];
                  final contactsInGroup = _contacts.where((c) => c.group == groupName).toList();
                  
                  return DragTarget<Contact>(
                    onWillAcceptWithDetails: (details) => details.data.group != groupName,
                    onAcceptWithDetails: (details) {
                      _moveContactToGroup(details.data, groupName);
                      setState(() {
                        _draggedOverGroup = null;
                      });
                    },
                    onMove: (details) {
                      if (_draggedOverGroup != groupName) {
                        setState(() {
                          _draggedOverGroup = groupName;
                        });
                      }
                    },
                    onLeave: (data) {
                      if (_draggedOverGroup == groupName) {
                        setState(() {
                          _draggedOverGroup = null;
                        });
                      }
                    },
                    builder: (context, candidateData, rejectedData) {
                      final isOver = candidateData.isNotEmpty || _draggedOverGroup == groupName;
                      
                      return Card(
                        margin: const EdgeInsets.only(bottom: 12),
                        elevation: isOver ? 4 : 1,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                          side: BorderSide(
                            color: isOver ? Colors.blueAccent : Colors.transparent,
                            width: isOver ? 2 : 0,
                          ),
                        ),
                        child: ExpansionTile(
                          initiallyExpanded: true,
                          leading: Icon(
                            groupName == 'Nuovi' ? Icons.folder_special : Icons.folder,
                            color: isOver ? Colors.blueAccent : Colors.blue,
                          ),
                          title: Row(
                            children: [
                              Text(
                                groupName,
                                style: const TextStyle(fontWeight: FontWeight.bold),
                              ),
                              const SizedBox(width: 8),
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                                decoration: BoxDecoration(
                                  color: Colors.grey.withValues(alpha: 0.2),
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                child: Text(
                                  '${contactsInGroup.length}',
                                  style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
                                ),
                              ),
                            ],
                          ),
                          trailing: groupName == 'Nuovi'
                              ? null
                              : IconButton(
                                  icon: const Icon(Icons.delete_outline, color: Colors.grey),
                                  onPressed: () => _deleteGroup(groupName),
                                ),
                          children: contactsInGroup.isEmpty
                              ? [
                                  const Padding(
                                    padding: EdgeInsets.symmetric(vertical: 16.0),
                                    child: Center(
                                      child: Text(
                                        'Trascina qui un contatto per aggiungerlo',
                                        style: TextStyle(color: Colors.grey, fontSize: 13),
                                      ),
                                    ),
                                  )
                                ]
                              : contactsInGroup.map((contact) {
                                  final nearbyUser = _getNearbyUser(contact);
                                  final statusColor = _getStatusColor(contact);
                                  final isOnline = _bluetoothService.connectedEndpoints.contains(contact.id);
                                  
                                  String statusText;
                                  if (isOnline) {
                                    if (nearbyUser != null) {
                                      if (nearbyUser.status == 'Nelle vicinanze') {
                                        statusText = 'Nelle vicinanze';
                                      } else {
                                        statusText = 'Nelle vicinanze (${nearbyUser.status})';
                                      }
                                    } else {
                                      statusText = 'Online';
                                    }
                                  } else {
                                    if (contact.lastSeen != null && contact.lastDistance != null) {
                                      final timeAgo = _formatLastSeen(contact.lastSeen!);
                                      statusText = 'Offline (Visto a ${contact.lastDistance!.toStringAsFixed(0)}m $timeAgo)';
                                    } else {
                                      statusText = 'Offline';
                                    }
                                  }

                                  final contactTile = Card(
                                    elevation: 0,
                                    margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                    color: Theme.of(context).cardColor.withValues(alpha: 0.5),
                                    child: ListTile(
                                      leading: GestureDetector(
                                        onTap: () => _showUserProfile(contact),
                                        child: Stack(
                                          children: [
                                            CircleAvatar(
                                              radius: 20,
					      backgroundImage: (contact.avatarPath != null && File(contact.avatarPath!).existsSync())
    					          ? FileImage(File(contact.avatarPath!)) 
                                                  : null,
                                              child: contact.avatarPath == null
                                                  ? Text(
                                                      contact.nickname[0].toUpperCase(),
                                                      style: const TextStyle(fontSize: 16),
                                                    )
                                                  : null,
                                            ),
                                            Positioned(
                                              right: 0,
                                              bottom: 0,
                                              child: Container(
                                                width: 11,
                                                height: 11,
                                                decoration: BoxDecoration(
                                                  color: statusColor,
                                                  shape: BoxShape.circle,
                                                  border: Border.all(
                                                    color: Theme.of(context).scaffoldBackgroundColor,
                                                    width: 1.5,
                                                  ),
                                                ),
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                      title: Text(contact.nickname, style: const TextStyle(fontSize: 15)),
                                      subtitle: Text(
                                        statusText,
                                        style: TextStyle(
                                          fontSize: 12,
                                          color: isOnline
                                              ? Colors.green
                                              : (nearbyUser != null ? Colors.orange : Colors.grey),
                                        ),
                                      ),
                                      trailing: Icon(
                                        isOnline ? Icons.chat : Icons.history,
                                        size: 20,
                                        color: isOnline ? Colors.blue : Colors.grey,
                                      ),
                                      onTap: () => _openChat(contact),
                                    ),
                                  );

                                  return LongPressDraggable<Contact>(
                                    data: contact,
                                    feedback: Material(
                                      elevation: 8,
                                      borderRadius: BorderRadius.circular(12),
                                      child: ConstrainedBox(
                                        constraints: BoxConstraints.tightFor(
                                          width: MediaQuery.of(context).size.width * 0.85,
                                        ),
                                        child: contactTile,
                                      ),
                                    ),
                                    childWhenDragging: Opacity(
                                      opacity: 0.3,
                                      child: contactTile,
                                    ),
                                    child: Dismissible(
                                      key: Key(contact.id),
                                      direction: DismissDirection.endToStart,
                                      background: Container(
                                        alignment: Alignment.centerRight,
                                        padding: const EdgeInsets.only(right: 16),
                                        color: Colors.red,
                                        child: const Icon(Icons.delete, color: Colors.white),
                                      ),
                                      confirmDismiss: (direction) async {
                                        return await showDialog<bool>(
                                          context: context,
                                          builder: (context) => AlertDialog(
                                            title: const Text('Elimina Contatto'),
                                            content: Text(
                                                'Vuoi eliminare ${contact.nickname} dalla rubrica? Verranno eliminati anche tutti i messaggi.'),
                                            actions: [
                                              TextButton(
                                                onPressed: () => Navigator.pop(context, false),
                                                child: const Text('Annulla'),
                                              ),
                                              TextButton(
                                                onPressed: () => Navigator.pop(context, true),
                                                child: const Text('Elimina',
                                                    style: TextStyle(color: Colors.red)),
                                              ),
                                            ],
                                          ),
                                        );
                                      },
                                      onDismissed: (direction) async {
                                        final scaffoldMessenger = ScaffoldMessenger.of(context);
                                        await _storageService.removeContact(contact.id);
                                        await _bluetoothService.revokeLocationSharing(contact.id);
                                        await _storageService.deleteChatHistory(contact.id);
                                        await _loadContacts();
                                        if (!mounted) return;
                                        scaffoldMessenger.showSnackBar(
                                          SnackBar(
                                              content: Text('${contact.nickname} e messaggi eliminati')),
                                        );
                                      },
                                      child: contactTile,
                                    ),
                                  );
                                }).toList(),
                        ),
                      );
                    },
                  );
                },
              ),
            ),
    );
  }

  String _formatLastSeen(DateTime dateTime) {
    final now = DateTime.now();
    final difference = now.difference(dateTime);
    
    if (difference.inSeconds < 60) {
      return 'poco fa';
    } else if (difference.inMinutes < 60) {
      return '${difference.inMinutes}m fa';
    } else if (difference.inHours < 24) {
      return '${difference.inHours}h fa';
    } else {
      return '${dateTime.day}/${dateTime.month} ${dateTime.hour}:${dateTime.minute.toString().padLeft(2, '0')}';
    }
  }

  @override
  void dispose() {
    super.dispose();
  }
}
