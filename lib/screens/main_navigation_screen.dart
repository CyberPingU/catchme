import 'package:flutter/material.dart';
import '../models/user_profile.dart';
import '../services/storage_service.dart';
import 'radar_screen.dart';
import 'contacts_screen.dart';
import 'profile_screen.dart';
import '../services/proximity_service.dart';

class MainNavigationScreen extends StatefulWidget {
  const MainNavigationScreen({super.key});

  @override
  State<MainNavigationScreen> createState() => _MainNavigationScreenState();
}

class _MainNavigationScreenState extends State<MainNavigationScreen> {
  int _currentIndex = 0;
  final _storageService = StorageService();
  final _bluetoothService = ProximityService();
  UserProfile? _profile;
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadProfile();
  }

  Future<void> _loadProfile() async {
    final profile = await _storageService.loadProfile();
    if (mounted) {
      setState(() {
        _profile = profile;
        _isLoading = false;
      });
    }
  }

  void _updateProfile(UserProfile profile) {
    setState(() {
      _profile = profile;
    });
    _bluetoothService.updateProfile(profile);
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }

    final bool hasProfile = _profile != null;

    if (!hasProfile) {
      return Scaffold(
        body: SafeArea(
          child: ProfileScreen(
            profile: null,
            onProfileSaved: _updateProfile,
          ),
        ),
      );
    }

    return Scaffold(
      body: IndexedStack(
        index: _currentIndex,
        children: [
          RadarScreen(profile: _profile),
          ContactsScreen(currentTab: _currentIndex),
          ProfileScreen(
            profile: _profile,
            onProfileSaved: _updateProfile,
          ),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _currentIndex,
        onDestinationSelected: (index) {
          setState(() => _currentIndex = index);
        },
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.radar),
            label: 'Radar',
          ),
          NavigationDestination(
            icon: Icon(Icons.contacts),
            label: 'Contatti',
          ),
          NavigationDestination(
            icon: Icon(Icons.person),
            label: 'Profilo',
          ),
        ],
      ),
    );
  }
}
