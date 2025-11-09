import 'dart:async';
import 'dart:math';
import 'dart:ui';

// ignore: unnecessary_import
import 'package:audio_service/audio_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
// import 'package:flutter/services.dart';
import 'package:just_audio/just_audio.dart';
import 'package:just_audio_background/just_audio_background.dart';
// import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'models/download_item.dart';
import 'models/user_script.dart';
import 'pages/downloads_page.dart';
import 'pages/home_page.dart';
import 'pages/settings_page.dart';
import 'pages/tabs_page.dart';
import 'widgets/bottom_nav.dart';
import 'widgets/address_bar.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Initialize background audio notification channel (for "Play in background" on media URLs)
  await JustAudioBackground.init(
    androidNotificationChannelId: 'com.example.tinybrowser.audio',
    androidNotificationChannelName: 'Background Media',
    androidNotificationOngoing: true,
  );

  final prefs = await SharedPreferences.getInstance();
  runApp(
    ChangeNotifierProvider(
      create: (_) => BrowserState(prefs)..loadFromPrefs(),
      child: const TinyBrowserApp(),
    ),
  );
}

class TinyBrowserApp extends StatelessWidget {
  const TinyBrowserApp({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<BrowserState>();
    final color = Colors.indigo;
    final scheme = ColorScheme.fromSeed(
      seedColor: color,
      brightness: state.darkMode ? Brightness.dark : Brightness.light,
    );
    return MaterialApp(
      title: 'Tiny Browser',
      debugShowCheckedModeBanner: false,
      themeMode: state.darkMode ? ThemeMode.dark : ThemeMode.light,
      theme: ThemeData(
        colorScheme: scheme,
        useMaterial3: true,
        appBarTheme: const AppBarTheme(
          centerTitle: false,
          scrolledUnderElevation: 0,
        ),
      ),
      darkTheme: ThemeData(colorScheme: scheme, useMaterial3: true),
      home: const RootScaffold(),
    );
  }
}

class RootScaffold extends StatefulWidget {
  const RootScaffold({super.key});

  @override
  State<RootScaffold> createState() => _RootScaffoldState();
}

class _RootScaffoldState extends State<RootScaffold>
    with TickerProviderStateMixin {
  late final TabController _tabController;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 4, vsync: this, initialIndex: 0);
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<BrowserState>();

    return Scaffold(
      extendBody: true,
      resizeToAvoidBottomInset: true,
      body: SafeArea(
        top: true,
        bottom: false,
        child: Column(
          children: [
            // Glass address bar
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 6),
              child: GlassContainer(
                child: AddressBar(
                  controller: state.addressController,
                  onGo: (value) => state.loadUrlOnCurrentTab(value),
                  onHome: () => _tabController.animateTo(0),
                  suggestionsBuilder: (q) => state.suggestions(q),
                ),
              ),
            ),
            Expanded(
              child: TabBarView(
                controller: _tabController,
                physics: const NeverScrollableScrollPhysics(),
                children: const [
                  HomePage(),
                  TabsPage(),
                  DownloadsPage(),
                  SettingsPage(),
                ],
              ),
            ),
          ],
        ),
      ),
      bottomNavigationBar: GlassContainer(
        margin: const EdgeInsets.fromLTRB(12, 0, 12, 12),
        child: BottomNav(
          currentIndex: _tabController.index,
          onChanged: (i) => setState(() => _tabController.index = i),
        ),
      ),
    );
  }
}

// Simple glassmorphism helper
class GlassContainer extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry? margin;
  const GlassContainer({super.key, required this.child, this.margin});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      margin: margin,
      decoration: BoxDecoration(
        color: scheme.surface.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: scheme.outline.withValues(alpha: 0.2)),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
          child: child,
        ),
      ),
    );
  }
}

// ======== App State ========
class BrowserTab {
  BrowserTab({
    required this.id,
    required this.initialUrl,
    this.isIncognito = false,
  });
  final String id;
  String title = '';
  String initialUrl;
  String? faviconUrl;
  bool isIncognito;
}

class BrowserState extends ChangeNotifier {
  BrowserState(this._prefs);
  final SharedPreferences _prefs;

  // Settings
  bool adBlockEnabled = true;
  bool darkMode = false;
  bool backgroundPlaybackEnabled = true;
  String homepage = 'https://www.google.com';

  // Background audio
  final AudioPlayer audioPlayer = AudioPlayer();

  // Scripts
  final List<UserScriptModel> scripts = [];

  // Tabs
  final List<BrowserTab> tabs = [];
  int currentTabIndex = 0;

  // Downloads
  final List<DownloadItem> downloads = [];

  // History & bookmarks (simple)
  final List<String> history = [];
  final List<String> bookmarks = [];

  // Address controller (shared)
  final TextEditingController addressController = TextEditingController();

  void loadFromPrefs() {
    adBlockEnabled = _prefs.getBool('adBlockEnabled') ?? true;
    darkMode = _prefs.getBool('darkMode') ?? false;
    backgroundPlaybackEnabled = _prefs.getBool('bgPlayback') ?? true;
    homepage = _prefs.getString('homepage') ?? homepage;
    bookmarks.addAll(_prefs.getStringList('bookmarks') ?? []);

    // Load scripts
    final rawScripts = _prefs.getStringList('scripts') ?? [];
    for (final s in rawScripts) {
      try {
        scripts.add(UserScriptModel.fromStorage(s));
      } catch (_) {}
    }
    if (scripts.isEmpty) {
      // Seed example script
      scripts.add(
        UserScriptModel(
          id: DateTime.now().millisecondsSinceEpoch.toString(),
          name: 'Hide basic ads',
          matchPattern: 'example.com',
          css:
              '.ad, .ads, [id^="ad"], [class*="ad"] { display:none !important; }',
          js: '',
        ),
      );
    }

    // Create initial tab
    if (tabs.isEmpty) {
      addTab(initialUrl: homepage);
    }
  }

  Future<void> persist() async {
    await _prefs.setBool('adBlockEnabled', adBlockEnabled);
    await _prefs.setBool('darkMode', darkMode);
    await _prefs.setBool('bgPlayback', backgroundPlaybackEnabled);
    await _prefs.setString('homepage', homepage);
    await _prefs.setStringList('bookmarks', bookmarks);
    await _prefs.setStringList(
      'scripts',
      scripts.map((e) => e.toStorage()).toList(),
    );
  }

  // Tabs
  void addTab({String initialUrl = 'about:blank', bool incognito = false}) {
    final id =
        'tab_${DateTime.now().millisecondsSinceEpoch}_${Random().nextInt(999)}';
    tabs.add(
      BrowserTab(id: id, initialUrl: initialUrl, isIncognito: incognito),
    );
    currentTabIndex = tabs.length - 1;
    notifyListeners();
  }

  void closeTab(int index) {
    if (index < 0 || index >= tabs.length) return;
    tabs.removeAt(index);
    if (currentTabIndex >= tabs.length) {
      currentTabIndex = max(0, tabs.length - 1);
    }
    if (tabs.isEmpty) {
      addTab(initialUrl: homepage);
    }
    notifyListeners();
  }

  void switchToTab(int index) {
    if (index < 0 || index >= tabs.length) return;
    currentTabIndex = index;
    notifyListeners();
  }

  void updateTabMeta(int index, {String? title, String? favicon}) {
    if (index < 0 || index >= tabs.length) return;
    if (title != null) tabs[index].title = title;
    if (favicon != null) tabs[index].faviconUrl = favicon;
    notifyListeners();
  }

  void setHomepage(String url) {
    homepage = url;
    persist();
    notifyListeners();
  }

  void toggleAdBlock(bool v) {
    adBlockEnabled = v;
    persist();
    notifyListeners();
  }

  void toggleDarkMode(bool v) {
    darkMode = v;
    persist();
    notifyListeners();
  }

  void toggleBgPlayback(bool v) {
    backgroundPlaybackEnabled = v;
    persist();
    notifyListeners();
  }

  void addBookmark(String url) {
    if (!bookmarks.contains(url)) {
      bookmarks.add(url);
      persist();
      notifyListeners();
    }
  }

  void removeBookmark(String url) {
    bookmarks.remove(url);
    persist();
    notifyListeners();
  }

  void recordHistory(String url) {
    if (url.startsWith('http')) {
      history.remove(url);
      history.insert(0, url);
      if (history.length > 100) history.removeLast();
    }
  }

  List<String> suggestions(String query) {
    if (query.isEmpty) return bookmarks.take(5).toList();
    final all = {...bookmarks, ...history}.toList();
    all.sort();
    return all
        .where((e) => e.toLowerCase().contains(query.toLowerCase()))
        .take(8)
        .toList();
  }

  // Navigation helpers
  void loadUrlOnCurrentTab(String input) {
    var text = input.trim();
    if (text.isEmpty) return;
    if (!text.startsWith('http://') && !text.startsWith('https://')) {
      // Treat as search query
      final encoded = Uri.encodeComponent(text);
      text = 'https://www.google.com/search?q=$encoded';
    }
    tabs[currentTabIndex].initialUrl = text;
    addressController.text = text;
    notifyListeners();
  }

  // Background playback for media URLs
  Future<void> playInBackground(String url, {String? title}) async {
    if (!backgroundPlaybackEnabled) return;
    try {
      await audioPlayer.setAudioSource(
        AudioSource.uri(
          Uri.parse(url),
          tag: MediaItem(
            id: url,
            title: title ?? 'Streaming',
            artUri: Uri.parse(
              'https://icons.duckduckgo.com/ip3/${Uri.parse(url).host}.ico',
            ),
          ),
        ),
      );
      await audioPlayer.play();
    } catch (e) {
      if (kDebugMode) debugPrint('BG play error: $e');
    }
  }

  // Downloads
  void addDownload(DownloadItem item) {
    downloads.insert(0, item);
    notifyListeners();
  }

  void updateDownload(DownloadItem item) {
    final i = downloads.indexWhere((d) => d.id == item.id);
    if (i != -1) {
      downloads[i] = item;
      notifyListeners();
    }
  }
}
