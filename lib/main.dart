import 'dart:async';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:firebase_core/firebase_core.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'firebase_options.dart';

// ----------- FIREBASE CONFIG -----------
const String apiKey = 'AIzaSyB14spd0k5x_4m6zZYWJAZLqBnI6jeZyBc';

// ------------- MODELOS -----------------
class UsuarioLogado {
  final String email;
  final String nome;
  final String uid;
  final String idToken;
  UsuarioLogado(
      {required this.email,
      required this.nome,
      required this.uid,
      required this.idToken});
}

UsuarioLogado? usuarioLogado;

class Cenario {
  final String? id;
  final String nome;
  final Map<String, bool> dispositivos;

  Cenario({this.id, required this.nome, required this.dispositivos});
}

// -------- PERFIL / CONTROLE DE USUÁRIOS ----------
class PerfilUsuario {
  final String uid;
  final String email;
  final String nome;
  final String role; // 'admin' | 'user'
  final bool ativo;
  final DateTime createdAt;

  PerfilUsuario({
    required this.uid,
    required this.email,
    required this.nome,
    required this.role,
    required this.ativo,
    required this.createdAt,
  });

  factory PerfilUsuario.fromMap(String uid, Map<String, dynamic> data) {
    return PerfilUsuario(
      uid: uid,
      email: data['email'] ?? '',
      nome: data['nome'] ?? '',
      role: data['role'] ?? 'user',
      ativo: data['ativo'] ?? true,
      createdAt: (data['createdAt'] as Timestamp?)?.toDate() ?? DateTime.now(),
    );
  }

  Map<String, dynamic> toMap() => {
        'email': email,
        'nome': nome,
        'role': role,
        'ativo': ativo,
        'createdAt': Timestamp.fromDate(createdAt),
      };
}

class UserService {
  static DocumentReference<Map<String, dynamic>> _perfilRef(String uid) =>
      FirebaseFirestore.instance.collection('usuarios').doc(uid);

  static Future<PerfilUsuario?> carregarPerfil(String uid) async {
    final doc = await _perfilRef(uid).get();
    if (!doc.exists) return null;
    return PerfilUsuario.fromMap(doc.id, doc.data()!);
  }

  /// Primeira conta vira admin de forma transacional usando /app_meta/hasAdmin
  static Future<void> criarPerfilBasico(User user, String nome) async {
    final db = FirebaseFirestore.instance;
    final usuarios = db.collection('usuarios');
    final hasAdminRef = db.collection('app_meta').doc('hasAdmin');

    await db.runTransaction((tx) async {
      final hasAdminSnap = await tx.get(hasAdminRef);
      final bool isFirstUser = !hasAdminSnap.exists;

      final dadosPerfil = <String, dynamic>{
        'email': user.email ?? '',
        'nome': (nome.isEmpty ? (user.email ?? '') : nome),
        'role': isFirstUser ? 'admin' : 'user',
        'ativo': true,
        'createdAt': FieldValue.serverTimestamp(),
      };

      tx.set(usuarios.doc(user.uid), dadosPerfil, SetOptions(merge: true));

      if (isFirstUser) {
        tx.set(hasAdminRef, {
          'value': true,
          'by': user.uid,
          'createdAt': FieldValue.serverTimestamp(),
        });
      }
    });
  }

  static Stream<List<PerfilUsuario>> streamTodos() {
    return FirebaseFirestore.instance
        .collection('usuarios')
        .orderBy('createdAt', descending: true)
        .snapshots()
        .map((s) =>
            s.docs.map((d) => PerfilUsuario.fromMap(d.id, d.data())).toList());
  }

  static Future<void> atualizarCampo(String uid, Map<String, dynamic> patch) {
    return _perfilRef(uid).update(patch);
  }
}

// ----------- FIREBASE AUTH --------
// LOGIN
Future<UsuarioLogado> loginWithEmail(String email, String password,
    {String? nome}) async {
  final credential = await FirebaseAuth.instance
      .signInWithEmailAndPassword(email: email, password: password);
  final user = credential.user;
  if (user == null) throw Exception('Falha no login');

  // carrega/valida perfil
  final perfil = await UserService.carregarPerfil(user.uid);
  if (perfil == null) {
    await UserService.criarPerfilBasico(user, nome ?? email);
  } else {
    if (perfil.ativo != true) {
      await FirebaseAuth.instance.signOut();
      throw Exception('Sua conta está desativada. Fale com o suporte.');
    }
  }

  return UsuarioLogado(
    email: email,
    nome: nome ?? (perfil?.nome ?? email),
    uid: user.uid,
    idToken: "",
  );
}

// CADASTRO
Future<UsuarioLogado> registerWithEmail(
    String email, String password, String nome) async {
  final credential = await FirebaseAuth.instance
      .createUserWithEmailAndPassword(email: email, password: password);
  final user = credential.user;
  if (user == null) throw Exception('Falha ao cadastrar');

  // cria perfil no Firestore
  await UserService.criarPerfilBasico(user, nome);

  return UsuarioLogado(
    email: email,
    nome: nome,
    uid: user.uid,
    idToken: "",
  );
}

// --------- SERVIÇO DE CENÁRIOS (FIRESTORE) ---------
class CenarioService {
  static CollectionReference<Map<String, dynamic>> _cenariosRef() {
    final usuario = usuarioLogado;
    if (usuario == null) throw Exception('Usuário não logado!');
    final uid = usuario.uid;
    return FirebaseFirestore.instance
        .collection('usuarios')
        .doc(uid)
        .collection('cenarios');
  }

  // (mantido para cenários; status agora é global via DispositivoService)

  static Future<List<Cenario>> buscarCenarios() async {
    final snap = await _cenariosRef().get();
    return snap.docs
        .map((doc) => Cenario(
              id: doc.id,
              nome: doc['nome'] ?? '',
              dispositivos: Map<String, bool>.from(doc['dispositivos'] ?? {}),
            ))
        .toList();
  }

  static Future<void> salvarCenario(Cenario cenario) async {
    final ref = _cenariosRef();
    try {
      if (cenario.id != null) {
        await ref.doc(cenario.id).set({
          'nome': cenario.nome,
          'dispositivos': cenario.dispositivos,
        });
      } else {
        await ref.doc(cenario.nome).set({
          'nome': cenario.nome,
          'dispositivos': cenario.dispositivos,
        });
      }
    } catch (e) {
      rethrow;
    }
  }

  static Future<void> excluirCenario(String id) async {
    await _cenariosRef().doc(id).delete();
  }
}

// ----------- STATUS GLOBAL & LOGS ---------------
class DispositivoInfo {
  final String nome;
  final bool ligado;
  final String updatedByUid;
  final String updatedByNome;
  final String updatedByEmail;
  final DateTime updatedAt;

  DispositivoInfo({
    required this.nome,
    required this.ligado,
    required this.updatedByUid,
    required this.updatedByNome,
    required this.updatedByEmail,
    required this.updatedAt,
  });

  factory DispositivoInfo.fromDoc(DocumentSnapshot<Map<String, dynamic>> d) {
    final data = d.data() ?? {};
    return DispositivoInfo(
      nome: d.id,
      ligado: (data['ligado'] ?? false) as bool,
      updatedByUid: data['updatedByUid'] ?? '',
      updatedByNome: data['updatedByNome'] ?? '',
      updatedByEmail: data['updatedByEmail'] ?? '',
      updatedAt: (data['updatedAt'] as Timestamp?)?.toDate() ?? DateTime.now(),
    );
  }
}

class DispositivoService {
  static CollectionReference<Map<String, dynamic>> _disps() =>
      FirebaseFirestore.instance.collection('dispositivos');

  static CollectionReference<Map<String, dynamic>> _logs() =>
      FirebaseFirestore.instance.collection('logs_dispositivos');

  /// Define o status global do dispositivo e grava um log (batch).
  static Future<void> setStatus(String nome, bool ligado) async {
    final u = usuarioLogado;
    if (u == null) throw Exception('Usuário não logado');

    final dispRef = _disps().doc(nome);
    final logRef = _logs().doc();

    final batch = FirebaseFirestore.instance.batch();
    batch.set(
        dispRef,
        {
          'ligado': ligado,
          'updatedByUid': u.uid,
          'updatedByNome': u.nome,
          'updatedByEmail': u.email,
          'updatedAt': FieldValue.serverTimestamp(),
        },
        SetOptions(merge: true));

    batch.set(logRef, {
      'dispositivo': nome,
      'ligado': ligado,
      'uid': u.uid,
      'nome': u.nome,
      'email': u.email,
      'ts': FieldValue.serverTimestamp(),
    });

    await batch.commit();
  }

  static Future<Map<String, bool>> carregarStatusGlobal() async {
    final snap = await _disps().get();
    final map = <String, bool>{};
    for (final d in snap.docs) {
      map[d.id] = (d.data()['ligado'] ?? false) as bool;
    }
    return map;
  }

  static Stream<List<DispositivoInfo>> streamDispositivos() {
    return _disps()
        .snapshots()
        .map((s) => s.docs.map(DispositivoInfo.fromDoc).toList());
  }

  static Stream<QuerySnapshot<Map<String, dynamic>>> streamLogs(
      {int limit = 200}) {
    return _logs().orderBy('ts', descending: true).limit(limit).snapshots();
  }
}

// ----------- CORES DO APP ---------------
const Color kGradientStart = Color(0xFF131A24);
const Color kGradientEnd = Color(0xFF222C36);
const Color kYellow = Color(0xFFFFB300);

// ----------- Comando ESP ---------------
Future<void> enviarComandoEsp(String endpoint) async {
  final url = Uri.parse('http://192.168.4.1$endpoint');
  try {
    final response = await http.get(url).timeout(const Duration(seconds: 4));
    print('Resposta ESP32: ${response.statusCode} ${response.body}');
  } catch (e) {
    print('Erro ao enviar comando: $e');
  }
}

// ----------- MAIN ---------------
void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Casa Inteligente',
      theme: ThemeData(
        fontFamily: 'Poppins',
        brightness: Brightness.dark,
        scaffoldBackgroundColor: Colors.transparent,
        colorScheme: const ColorScheme.dark(primary: kYellow),
      ),
      home: const LoginPage(),
    );
  }
}

// ---------------- LOGIN PAGE --------------
class LoginPage extends StatefulWidget {
  const LoginPage({super.key});
  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final userController = TextEditingController();
  final passController = TextEditingController();
  String? erroMsg;

  void tentarLogin() async {
    final emailOuUsuario = userController.text.trim();
    final senha = passController.text;

    setState(() => erroMsg = null);

    if (emailOuUsuario.isEmpty) {
      setState(() => erroMsg = "E-mail é obrigatório.");
      return;
    }
    if (senha.isEmpty) {
      setState(() => erroMsg = "Senha é obrigatória.");
      return;
    }

    try {
      final usuario = await loginWithEmail(emailOuUsuario, senha);
      usuarioLogado = usuario;
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (_) => const HomePage()),
      );
    } catch (e) {
      setState(() => erroMsg = e.toString().replaceFirst('Exception: ', ''));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            colors: [kGradientStart, kGradientEnd],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
        ),
        child: Center(
          child: SingleChildScrollView(
            child: Container(
              width: 370,
              padding: const EdgeInsets.all(32),
              decoration: BoxDecoration(
                color: Colors.black.withOpacity(0.4),
                borderRadius: BorderRadius.circular(24),
                boxShadow: const [
                  BoxShadow(
                      color: Colors.black26,
                      blurRadius: 32,
                      spreadRadius: 0,
                      offset: Offset(0, 12)),
                ],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Stack(
                    children: [
                      const CircleAvatar(
                        radius: 44,
                        backgroundColor: kYellow,
                        child: Icon(Icons.home, size: 44, color: Colors.black),
                      ),
                      Positioned(
                        right: 0,
                        bottom: 0,
                        child: CircleAvatar(
                          radius: 18,
                          backgroundColor: kYellow,
                          child: const Icon(Icons.wifi,
                              color: Colors.black, size: 18),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 22),
                  const Text(
                    'Bem-vindo',
                    style: TextStyle(fontSize: 32, fontWeight: FontWeight.bold),
                  ),
                  const Text(
                    'Controle sua casa inteligente',
                    style: TextStyle(fontSize: 15, color: Colors.white60),
                  ),
                  const SizedBox(height: 28),
                  TextField(
                    controller: userController,
                    style: const TextStyle(color: Colors.white),
                    decoration: InputDecoration(
                      labelText: 'E-mail',
                      labelStyle: const TextStyle(color: Colors.white54),
                      filled: true,
                      fillColor: Colors.black38,
                      border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12)),
                    ),
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: passController,
                    obscureText: true,
                    style: const TextStyle(color: Colors.white),
                    decoration: InputDecoration(
                      labelText: 'Senha',
                      labelStyle: const TextStyle(color: Colors.white54),
                      filled: true,
                      fillColor: Colors.black38,
                      border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12)),
                    ),
                  ),
                  if (erroMsg != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 10, bottom: 2),
                      child: Text(
                        erroMsg!,
                        style: const TextStyle(
                            color: Colors.redAccent, fontSize: 15),
                      ),
                    ),
                  const SizedBox(height: 24),
                  SizedBox(
                    width: double.infinity,
                    height: 46,
                    child: ElevatedButton(
                      onPressed: tentarLogin,
                      style: ElevatedButton.styleFrom(
                        padding: EdgeInsets.zero,
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12)),
                        backgroundColor: Colors.transparent,
                        shadowColor: Colors.transparent,
                        elevation: 0,
                      ),
                      child: Ink(
                        decoration: BoxDecoration(
                          gradient: const LinearGradient(
                            colors: [Color(0xFFFFB300), Color(0xFFFF9000)],
                          ),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Container(
                          alignment: Alignment.center,
                          child: const Text(
                            'Entrar',
                            style: TextStyle(
                              color: Colors.black,
                              fontWeight: FontWeight.bold,
                              fontSize: 18,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                  TextButton(
                    onPressed: () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(builder: (_) => const RegisterPage()),
                      );
                    },
                    child: const Text(
                      'Criar nova conta',
                      style: TextStyle(color: kYellow),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// --------------- REGISTER PAGE ---------------
class RegisterPage extends StatefulWidget {
  const RegisterPage({super.key});
  @override
  State<RegisterPage> createState() => _RegisterPageState();
}

class _RegisterPageState extends State<RegisterPage> {
  final userController = TextEditingController();
  final emailController = TextEditingController();
  final passController = TextEditingController();
  final confirmPassController = TextEditingController();
  String? erroMsg;

  void tentarCadastro() async {
    final nome = userController.text.trim();
    final email = emailController.text.trim();
    final senha = passController.text;
    final confirmarSenha = confirmPassController.text;

    setState(() => erroMsg = null);

    if (nome.isEmpty) {
      setState(() => erroMsg = "Nome de usuário é obrigatório.");
      return;
    }
    if (email.isEmpty) {
      setState(() => erroMsg = "E-mail é obrigatório.");
      return;
    }
    if (senha.isEmpty) {
      setState(() => erroMsg = "Senha é obrigatória.");
      return;
    }
    if (confirmarSenha.isEmpty) {
      setState(() => erroMsg = "Confirme sua senha.");
      return;
    }
    if (!email.contains('@')) {
      setState(() => erroMsg = "E-mail inválido.");
      return;
    }
    if (senha.length < 4) {
      setState(() => erroMsg = "Senha muito curta.");
      return;
    }
    if (senha != confirmarSenha) {
      setState(() => erroMsg = "As senhas não coincidem.");
      return;
    }

    try {
      final usuario = await registerWithEmail(email, senha, nome);
      usuarioLogado = usuario;
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Conta criada com sucesso!")),
      );
      Navigator.pop(context);
    } catch (e) {
      setState(() => erroMsg = e.toString().replaceFirst('Exception: ', ''));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: kGradientStart,
        elevation: 0,
        centerTitle: true,
        title: const Text(
          "Criar Conta",
          style: TextStyle(
            fontWeight: FontWeight.bold,
            fontSize: 23,
            color: Colors.white,
            letterSpacing: 0.5,
          ),
        ),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Colors.white70),
          onPressed: () => Navigator.pop(context),
        ),
      ),
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            colors: [kGradientStart, kGradientEnd],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
        ),
        child: Center(
          child: SingleChildScrollView(
            child: Container(
              width: 370,
              padding: const EdgeInsets.all(32),
              decoration: BoxDecoration(
                color: Colors.black.withOpacity(0.4),
                borderRadius: BorderRadius.circular(24),
                boxShadow: const [
                  BoxShadow(
                      color: Colors.black26,
                      blurRadius: 32,
                      spreadRadius: 0,
                      offset: Offset(0, 12)),
                ],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const CircleAvatar(
                    radius: 44,
                    backgroundColor: kYellow,
                    child:
                        Icon(Icons.person_add, size: 44, color: Colors.black),
                  ),
                  const SizedBox(height: 22),
                  const Text(
                    'Crie sua Conta',
                    style: TextStyle(fontSize: 32, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 18),
                  TextField(
                    controller: userController,
                    style: const TextStyle(color: Colors.white),
                    decoration: InputDecoration(
                      labelText: 'Nome de usuário',
                      labelStyle: const TextStyle(color: Colors.white54),
                      filled: true,
                      fillColor: Colors.black38,
                      border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12)),
                    ),
                  ),
                  const SizedBox(height: 14),
                  TextField(
                    controller: emailController,
                    style: const TextStyle(color: Colors.white),
                    decoration: InputDecoration(
                      labelText: 'E-mail',
                      labelStyle: const TextStyle(color: Colors.white54),
                      filled: true,
                      fillColor: Colors.black38,
                      border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12)),
                    ),
                  ),
                  const SizedBox(height: 14),
                  TextField(
                    controller: passController,
                    obscureText: true,
                    style: const TextStyle(color: Colors.white),
                    decoration: InputDecoration(
                      labelText: 'Senha',
                      labelStyle: const TextStyle(color: Colors.white54),
                      filled: true,
                      fillColor: Colors.black38,
                      border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12)),
                    ),
                  ),
                  const SizedBox(height: 14),
                  TextField(
                    controller: confirmPassController,
                    obscureText: true,
                    style: const TextStyle(color: Colors.white),
                    decoration: InputDecoration(
                      labelText: 'Confirmar Senha',
                      labelStyle: const TextStyle(color: Colors.white54),
                      filled: true,
                      fillColor: Colors.black38,
                      border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12)),
                    ),
                  ),
                  if (erroMsg != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 10, bottom: 2),
                      child: Text(
                        erroMsg!,
                        style: const TextStyle(
                            color: Colors.redAccent, fontSize: 15),
                      ),
                    ),
                  const SizedBox(height: 18),
                  SizedBox(
                    width: double.infinity,
                    height: 46,
                    child: ElevatedButton(
                      onPressed: tentarCadastro,
                      style: ElevatedButton.styleFrom(
                        padding: EdgeInsets.zero,
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12)),
                        backgroundColor: Colors.transparent,
                        shadowColor: Colors.transparent,
                        elevation: 0,
                      ),
                      child: Ink(
                        decoration: BoxDecoration(
                          gradient: const LinearGradient(
                            colors: [Color(0xFFFFB300), Color(0xFFFF9000)],
                          ),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Container(
                          alignment: Alignment.center,
                          child: const Text(
                            'Criar Conta',
                            style: TextStyle(
                              color: Colors.black,
                              fontWeight: FontWeight.bold,
                              fontSize: 18,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextButton(
                    onPressed: () {
                      Navigator.pop(context);
                    },
                    child: const Text(
                      'Já tenho uma conta',
                      style: TextStyle(color: kYellow),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// -------------- HOME PAGE -------------------
class HomePage extends StatefulWidget {
  const HomePage({super.key});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  int selectedTab = 0;
  late PageController _pageController;
  Map<int, bool> statusCenarios = {};

  // Perfil
  PerfilUsuario? _perfil;

  // Listener global de dispositivos
  StreamSubscription<List<DispositivoInfo>>? _dispSub;

  // Luzes e outros controles
  bool todasLuzes = false;
  bool sala = false;
  bool cozinha = false;
  bool banheiro = false;
  bool quarto = false;

  bool ventPrimeiroAndar = false;
  bool ventSegundoAndar = false;

  bool portaoAberto = false;

  // -------------------- CENÁRIOS FIRESTORE ---------------------
  List<Cenario> cenarios = [];
  bool loadingCenarios = true;

  @override
  void initState() {
    super.initState();
    _pageController = PageController(initialPage: selectedTab);
    _carregarCenarios();
    _carregarStatusDispositivos(); // agora global
    _carregarPerfil();
    _iniciarListenerDispositivos(); // escuta mudanças globais em tempo real
  }

  void _iniciarListenerDispositivos() {
    _dispSub = DispositivoService.streamDispositivos().listen((lista) {
      final map = {for (final d in lista) d.nome: d.ligado};
      setState(() {
        // Luzes
        sala = map['Sala'] ?? false;
        cozinha = map['Cozinha'] ?? false;
        banheiro = map['Banheiro'] ?? false;
        quarto = map['Quarto'] ?? false;
        todasLuzes = sala && cozinha && banheiro && quarto;

        // Ventiladores
        ventPrimeiroAndar = map['VentPrimeiroAndar'] ?? false;
        ventSegundoAndar = map['VentSegundoAndar'] ?? false;

        // Portão
        portaoAberto = map['Portao'] ?? false;
      });
    });
  }

  Future<void> _carregarPerfil() async {
    final u = usuarioLogado;
    if (u == null) return;
    final p = await UserService.carregarPerfil(u.uid);
    setState(() => _perfil = p);
  }

  Future<void> _carregarCenarios() async {
    setState(() => loadingCenarios = true);
    try {
      final lista = await CenarioService.buscarCenarios();
      setState(() {
        cenarios = lista;
        loadingCenarios = false;
      });
    } catch (e) {
      setState(() => loadingCenarios = false);
    }
  }

  Future<void> _carregarStatusDispositivos() async {
    try {
      final status = await DispositivoService.carregarStatusGlobal();
      setState(() {
        sala = status["Sala"] ?? false;
        cozinha = status["Cozinha"] ?? false;
        banheiro = status["Banheiro"] ?? false;
        quarto = status["Quarto"] ?? false;
        todasLuzes = sala && cozinha && banheiro && quarto;

        ventPrimeiroAndar = status["VentPrimeiroAndar"] ?? false;
        ventSegundoAndar = status["VentSegundoAndar"] ?? false;

        portaoAberto = status['Portao'] ?? false;
      });
    } catch (e) {
      print('Erro ao carregar status global: $e');
    }
  }

  Future<void> _adicionarOuEditarCenario(Cenario novo, {int? index}) async {
    if (index != null) {
      final cenarioAtual = cenarios[index];
      final atualizado = Cenario(
          id: cenarioAtual.id,
          nome: novo.nome,
          dispositivos: novo.dispositivos);
      await CenarioService.salvarCenario(atualizado);
      setState(() {
        cenarios[index] = atualizado;
      });
    } else {
      await CenarioService.salvarCenario(novo);
      await _carregarCenarios();
    }
  }

  Future<void> _excluirCenario(int index) async {
    final id = cenarios[index].id;
    if (id != null) {
      await CenarioService.excluirCenario(id);
      setState(() {
        cenarios.removeAt(index);
      });
    }
  }

  @override
  void dispose() {
    _dispSub?.cancel();
    _pageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        backgroundColor: kGradientStart,
        elevation: 0,
        centerTitle: true,
        leading: const Padding(
          padding: EdgeInsets.only(left: 12),
          child: CircleAvatar(
            backgroundColor: kYellow,
            child: Icon(Icons.home, color: Colors.black, size: 26),
          ),
        ),
        title: const Text(
          "Casa Inteligente",
          style: TextStyle(
            fontWeight: FontWeight.bold,
            fontSize: 23,
            color: Colors.white,
            letterSpacing: 0.5,
          ),
        ),
        actions: [
          if (_perfil?.role == 'admin')
            IconButton(
              icon: const Icon(Icons.history, color: Colors.white70, size: 26),
              tooltip: "Logs de Dispositivos",
              onPressed: () {
                Navigator.push(context,
                    MaterialPageRoute(builder: (_) => const DeviceLogsPage()));
              },
            ),
          if (_perfil?.role == 'admin')
            IconButton(
              icon: const Icon(Icons.supervisor_account,
                  color: Colors.white70, size: 26),
              tooltip: "Controle de Usuários",
              onPressed: () {
                Navigator.push(context,
                    MaterialPageRoute(builder: (_) => const AdminUsersPage()));
              },
            ),
          IconButton(
            icon: const Icon(Icons.person, color: Colors.white70, size: 26),
            tooltip: "Meu Perfil",
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const PerfilPage()),
              );
            },
          ),
          IconButton(
            icon: const Icon(Icons.logout, color: Colors.white70, size: 26),
            tooltip: "Sair",
            onPressed: () async {
              await FirebaseAuth.instance.signOut();
              usuarioLogado = null;
              if (!mounted) return;
              Navigator.pushReplacement(
                context,
                MaterialPageRoute(builder: (_) => const LoginPage()),
              );
            },
          ),
          const SizedBox(width: 8)
        ],
      ),
      body: Container(
        width: double.infinity,
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            colors: [kGradientStart, kGradientEnd],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
        ),
        child: Column(
          children: [
            Padding(
              padding:
                  const EdgeInsets.symmetric(horizontal: 24.0, vertical: 4),
              child: Row(
                children: [
                  _modernTab(0, Icons.lightbulb, "Luzes"),
                  _modernTab(1, Icons.air, "Ventilação"),
                  _modernTab(2, Icons.garage, "Portão"),
                  _modernTab(3, Icons.auto_awesome, "Cenários"),
                ],
              ),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: PageView(
                controller: _pageController,
                onPageChanged: (index) {
                  setState(() {
                    selectedTab = index;
                  });
                },
                children: [
                  _buildTabContent(0),
                  _buildTabContent(1),
                  _buildTabContent(2),
                  loadingCenarios
                      ? const Center(child: CircularProgressIndicator())
                      : CenariosPage(
                          cenarios: cenarios,
                          onSalvar: _adicionarOuEditarCenario,
                          onExcluir: _excluirCenario,
                          statusCenarios: statusCenarios,
                          onStatusChanged: (index, valor) {
                            setState(() {
                              statusCenarios[index] = valor;
                            });
                          },
                        )
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _modernTab(int idx, IconData icon, String label) {
    final selected = selectedTab == idx;
    return Expanded(
      child: GestureDetector(
        onTap: () {
          setState(() {
            selectedTab = idx;
            _pageController.animateToPage(
              idx,
              duration: const Duration(milliseconds: 350),
              curve: Curves.ease,
            );
          });
        },
        child: Container(
          height: 40,
          margin: const EdgeInsets.symmetric(horizontal: 3),
          decoration: BoxDecoration(
            color: selected ? kYellow : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon,
                  color: selected ? Colors.black : Colors.white54, size: 22),
              const SizedBox(width: 6),
              Text(label,
                  style: TextStyle(
                    color: selected ? Colors.black : Colors.white54,
                    fontWeight: FontWeight.bold,
                    fontSize: 15,
                  )),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTabContent(int tab) {
    if (tab == 0) {
      // Luzes
      return ListView(
        key: const ValueKey(0),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        children: [
          _smartCard(
            icon: Icons.home,
            title: "Todas as Luzes",
            subtitle: todasLuzes ? "Ligada" : "Desligada",
            value: todasLuzes,
            onChanged: (v) async {
              setState(() {
                todasLuzes = v;
                sala = v;
                cozinha = v;
                banheiro = v;
                quarto = v;
              });
              await enviarComandoEsp(v ? '/ligar/Sala' : '/desligar/Sala');
              await enviarComandoEsp(
                  v ? '/ligar/Cozinha' : '/desligar/Cozinha');
              await enviarComandoEsp(
                  v ? '/ligar/Banheiro' : '/desligar/Banheiro');
              await enviarComandoEsp(v ? '/ligar/Quarto' : '/desligar/Quarto');

              await DispositivoService.setStatus("Sala", v);
              await DispositivoService.setStatus("Cozinha", v);
              await DispositivoService.setStatus("Banheiro", v);
              await DispositivoService.setStatus("Quarto", v);
            },
          ),
          _smartCard(
            icon: Icons.weekend,
            title: "Sala",
            subtitle: sala ? "Ligada" : "Desligada",
            value: sala,
            onChanged: (v) async {
              setState(() {
                sala = v;
                todasLuzes = sala && cozinha && banheiro && quarto;
              });
              await enviarComandoEsp(v ? '/ligar/Sala' : '/desligar/Sala');
              await DispositivoService.setStatus("Sala", v);
            },
          ),
          _smartCard(
            icon: Icons.kitchen,
            title: "Cozinha",
            subtitle: cozinha ? "Ligada" : "Desligada",
            value: cozinha,
            onChanged: (v) async {
              setState(() {
                cozinha = v;
                todasLuzes = sala && cozinha && banheiro && quarto;
              });
              await enviarComandoEsp(
                  v ? '/ligar/Cozinha' : '/desligar/Cozinha');
              await DispositivoService.setStatus("Cozinha", v);
            },
          ),
          _smartCard(
            icon: Icons.bathtub,
            title: "Banheiro",
            subtitle: banheiro ? "Ligada" : "Desligada",
            value: banheiro,
            onChanged: (v) async {
              setState(() {
                banheiro = v;
                todasLuzes = sala && cozinha && banheiro && quarto;
              });
              await enviarComandoEsp(
                  v ? '/ligar/Banheiro' : '/desligar/Banheiro');
              await DispositivoService.setStatus("Banheiro", v);
            },
          ),
          _smartCard(
            icon: Icons.bed,
            title: "Quarto",
            subtitle: quarto ? "Ligada" : "Desligada",
            value: quarto,
            onChanged: (v) async {
              setState(() {
                quarto = v;
                todasLuzes = sala && cozinha && banheiro && quarto;
              });
              await enviarComandoEsp(v ? '/ligar/Quarto' : '/desligar/Quarto');
              await DispositivoService.setStatus("Quarto", v);
            },
          ),
        ],
      );
    } else if (tab == 1) {
      // Ventilação
      return ListView(
        key: const ValueKey(1),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        children: [
          _ventCard(
            title: "Primeiro andar",
            value: ventPrimeiroAndar,
            onChanged: (v) async {
              setState(() {
                ventPrimeiroAndar = v;
              });

              // Se seu ESP32 não diferencia por cômodo, o endpoint geral segue igual:
              await enviarComandoEsp(
                  v ? '/ventilador/ligar' : '/ventilador/desligar');

              // Status global consolidado por andar
              await DispositivoService.setStatus("VentPrimeiroAndar", v);
            },
          ),

          // SEGUNDO ANDAR:
          _ventCard(
            title: "Segundo andar",
            value: ventSegundoAndar,
            onChanged: (v) async {
              setState(() {
                ventSegundoAndar = v;
              });

              await enviarComandoEsp(
                  v ? '/ventilador/ligar' : '/ventilador/desligar');

              await DispositivoService.setStatus("VentSegundoAndar", v);
            },
          ),
        ],
      );
    } else if (tab == 2) {
      // Portão
      return Center(
        key: const ValueKey(2),
        child: Container(
          width: 360,
          padding: const EdgeInsets.all(24),
          decoration: BoxDecoration(
            color: Colors.white.withOpacity(0.06),
            borderRadius: BorderRadius.circular(22),
            border: Border.all(color: Colors.white12),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const CircleAvatar(
                backgroundColor: Colors.white12,
                radius: 34,
                child: Icon(Icons.garage, color: Colors.white70, size: 38),
              ),
              const SizedBox(height: 18),
              const Text(
                "Portão da Garagem",
                style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w700,
                    fontSize: 22),
              ),
              const SizedBox(height: 12),
              Text(
                portaoAberto ? "Aberto" : "Fechado",
                style: TextStyle(
                  color: portaoAberto ? Colors.greenAccent : Colors.redAccent,
                  fontSize: 18,
                  fontWeight: FontWeight.w500,
                ),
              ),
              const SizedBox(height: 32),
              SizedBox(
                width: double.infinity,
                height: 52,
                child: ElevatedButton.icon(
                  icon: Icon(portaoAberto ? Icons.lock : Icons.lock_open,
                      color: Colors.black, size: 28),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: kYellow,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12)),
                    elevation: 0,
                  ),
                  onPressed: () async {
                    setState(() {
                      portaoAberto = !portaoAberto;
                    });
                    await enviarComandoEsp(
                        portaoAberto ? '/portao/abrir' : '/portao/fechar');
                    await DispositivoService.setStatus("Portao", portaoAberto);
                  },
                  label: Text(
                    portaoAberto ? "Fechar Portão" : "Abrir Portão",
                    style: const TextStyle(
                        color: Colors.black,
                        fontSize: 18,
                        fontWeight: FontWeight.bold),
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    }
    return Container();
  }

  Widget _smartCard({
    required IconData icon,
    required String title,
    required String subtitle,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 10),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.05),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.white12),
      ),
      child: Row(
        children: [
          CircleAvatar(
            backgroundColor: Colors.white12,
            radius: 26,
            child: Icon(icon, color: Colors.white70, size: 26),
          ),
          const SizedBox(width: 18),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w600,
                    fontSize: 19,
                  ),
                ),
                Text(
                  subtitle,
                  style: const TextStyle(
                    color: Colors.white54,
                    fontSize: 15,
                    fontWeight: FontWeight.normal,
                  ),
                ),
              ],
            ),
          ),
          Switch(
            value: value,
            onChanged: onChanged,
            activeColor: kYellow,
          ),
        ],
      ),
    );
  }

  Widget _ventCard({
    required String title,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 10),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.05),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.white12),
      ),
      child: Row(
        children: [
          const CircleAvatar(
            backgroundColor: Colors.white12,
            radius: 26,
            child: Icon(Icons.air, color: Colors.white70, size: 28),
          ),
          const SizedBox(width: 18),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w600,
                    fontSize: 19,
                  ),
                ),
                Text(
                  value ? "Ligado" : "Desligado",
                  style: const TextStyle(
                    color: Colors.white54,
                    fontSize: 15,
                    fontWeight: FontWeight.normal,
                  ),
                ),
              ],
            ),
          ),
          Switch(
            value: value,
            onChanged: onChanged,
            activeColor: kYellow,
          ),
        ],
      ),
    );
  }
}

// -------- PERFIL PAGE  -----
class PerfilPage extends StatelessWidget {
  const PerfilPage({super.key});

  @override
  Widget build(BuildContext context) {
    final usuario = usuarioLogado;

    return Scaffold(
      appBar: AppBar(
        backgroundColor: kGradientStart,
        elevation: 0,
        title: const Text(
          "Meu Perfil",
          style: TextStyle(
            fontWeight: FontWeight.bold,
            fontSize: 22,
            color: Colors.white,
          ),
        ),
        centerTitle: true,
      ),
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            colors: [kGradientStart, kGradientEnd],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
        ),
        width: double.infinity,
        child: usuario == null
            ? const Center(
                child: Text(
                  "Nenhum usuário encontrado.",
                  style: TextStyle(color: Colors.white70, fontSize: 18),
                ),
              )
            : FutureBuilder<PerfilUsuario?>(
                future: UserService.carregarPerfil(usuario.uid),
                builder: (context, snap) {
                  final perfil = snap.data;
                  return Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const CircleAvatar(
                        radius: 48,
                        backgroundColor: kYellow,
                        child:
                            Icon(Icons.person, size: 54, color: Colors.black),
                      ),
                      const SizedBox(height: 18),
                      if (usuario.nome != usuario.email)
                        Text(
                          usuario.nome,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 28,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      if (usuario.nome == usuario.email || usuario.nome.isEmpty)
                        Text(
                          usuario.email,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 28,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      if (usuario.nome != usuario.email)
                        const SizedBox(height: 8),
                      if (usuario.nome != usuario.email)
                        Text(
                          usuario.email,
                          style: const TextStyle(
                            color: Colors.white70,
                            fontSize: 18,
                          ),
                        ),
                      if (perfil != null) ...[
                        const SizedBox(height: 8),
                        Text(
                          'Função: ${perfil.role} • ${perfil.ativo ? "ativo" : "inativo"}',
                          style: const TextStyle(color: Colors.white70),
                        ),
                      ],
                      const SizedBox(height: 40),
                      ElevatedButton.icon(
                        icon: const Icon(Icons.logout, color: Colors.black),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: kYellow,
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(14)),
                          padding: const EdgeInsets.symmetric(
                              horizontal: 22, vertical: 14),
                        ),
                        onPressed: () async {
                          await FirebaseAuth.instance.signOut();
                          usuarioLogado = null;
                          Navigator.pushAndRemoveUntil(
                            context,
                            MaterialPageRoute(
                                builder: (_) => const LoginPage()),
                            (route) => false,
                          );
                        },
                        label: const Text(
                          'Sair da Conta',
                          style: TextStyle(
                            color: Colors.black,
                            fontWeight: FontWeight.bold,
                            fontSize: 17,
                          ),
                        ),
                      ),
                    ],
                  );
                },
              ),
      ),
    );
  }
}

// ---------- CENÁRIOS PAGE  -----------
class CenariosPage extends StatefulWidget {
  final List<Cenario> cenarios;
  final void Function(Cenario, {int? index}) onSalvar;
  final void Function(int index) onExcluir;
  final Map<int, bool> statusCenarios;
  final void Function(int index, bool valor) onStatusChanged;

  const CenariosPage({
    super.key,
    required this.cenarios,
    required this.onSalvar,
    required this.onExcluir,
    required this.statusCenarios,
    required this.onStatusChanged,
  });

  @override
  State<CenariosPage> createState() => _CenariosPageState();
}

class _CenariosPageState extends State<CenariosPage> {
  Future<void> _executarCenario(Cenario cenario, bool ligar) async {
    for (var entry in cenario.dispositivos.entries) {
      final dispositivo = entry.key;
      final estado = ligar ? entry.value : false;

      if (dispositivo == 'Portao') {
        await enviarComandoEsp(estado ? '/portao/abrir' : '/portao/fechar');
        await DispositivoService.setStatus("Portao", estado);
      } else if (dispositivo == 'VentPrimeiroAndar') {
        // Se seu ESP tiver endpoints separados, troque por /vent1/ligar|desligar
        await enviarComandoEsp(
            estado ? '/ventilador/ligar' : '/ventilador/desligar');
        await DispositivoService.setStatus("VentPrimeiroAndar", estado);
      } else if (dispositivo == 'VentSegundoAndar') {
        // Se tiver endpoint separado, troque por /vent2/ligar|desligar
        await enviarComandoEsp(
            estado ? '/ventilador/ligar' : '/ventilador/desligar');
        await DispositivoService.setStatus("VentSegundoAndar", estado);
      } else {
        // Luzes: Sala, Cozinha, Banheiro, Quarto
        await enviarComandoEsp(
            estado ? '/ligar/$dispositivo' : '/desligar/$dispositivo');
        await DispositivoService.setStatus(dispositivo, estado);
      }
    }

    // Atualiza switches da HomePage
    final homeState = context.findAncestorStateOfType<_HomePageState>();
    if (homeState != null) {
      await homeState._carregarStatusDispositivos();
    }
  }

  @override
  Widget build(BuildContext context) {
    final cenarios = widget.cenarios;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                "Cenários Salvos",
                style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                    color: Colors.white),
              ),
              ElevatedButton.icon(
                onPressed: () {
                  showDialog(
                    context: context,
                    builder: (_) => Dialog(
                      child: CenarioForm(
                        onSalvar: (novo) {
                          widget.onSalvar(novo);
                          Navigator.of(context).pop();
                        },
                      ),
                    ),
                  );
                },
                icon: const Icon(Icons.add),
                label: const Text("Novo Cenário"),
                style: ElevatedButton.styleFrom(
                    backgroundColor: kYellow, foregroundColor: Colors.black),
              )
            ],
          ),
        ),
        Expanded(
          child: cenarios.isEmpty
              ? const Center(
                  child: Text("Nenhum cenário criado ainda.",
                      style: TextStyle(color: Colors.white70)),
                )
              : ListView.builder(
                  itemCount: cenarios.length,
                  itemBuilder: (_, index) {
                    final c = cenarios[index];
                    final ligado = widget.statusCenarios[index] ?? false;
                    return Card(
                      color: Colors.white10,
                      margin: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 8),
                      child: ListTile(
                        title: Text(c.nome,
                            style: const TextStyle(color: Colors.white)),
                        subtitle: Text(
                          c.dispositivos.entries
                                  .where((e) => e.value)
                                  .map((e) => e.key)
                                  .join(", ") +
                              (ligado ? "  [Ativado]" : "  [Desativado]"),
                          style: const TextStyle(color: Colors.white54),
                        ),
                        trailing: Wrap(
                          spacing: 4,
                          children: [
                            IconButton(
                              icon: const Icon(Icons.edit,
                                  color: Colors.orangeAccent),
                              onPressed: () {
                                showDialog(
                                  context: context,
                                  builder: (_) => Dialog(
                                    child: CenarioForm(
                                      cenario: c,
                                      onSalvar: (novo) {
                                        widget.onSalvar(novo, index: index);
                                        Navigator.of(context).pop();
                                      },
                                    ),
                                  ),
                                );
                              },
                              tooltip: 'Editar',
                            ),
                            IconButton(
                              icon: const Icon(Icons.delete,
                                  color: Colors.redAccent),
                              onPressed: () {
                                widget.onExcluir(index);
                                widget.onStatusChanged(index, false);
                              },
                              tooltip: 'Excluir',
                            ),
                            Switch(
                              value: ligado,
                              activeColor: Colors.greenAccent,
                              onChanged: (v) async {
                                widget.onStatusChanged(index, v);
                                await _executarCenario(c, v);
                                if (!mounted) return;
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(
                                    content: Text(
                                      v
                                          ? 'Cenário ativado!'
                                          : 'Cenário desativado!',
                                    ),
                                    duration: const Duration(seconds: 1),
                                  ),
                                );
                              },
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }
}

class CenarioForm extends StatefulWidget {
  final Cenario? cenario;
  final void Function(Cenario) onSalvar;
  const CenarioForm({super.key, this.cenario, required this.onSalvar});
  @override
  State<CenarioForm> createState() => _CenarioFormState();
}

class _CenarioFormState extends State<CenarioForm> {
  final nomeController = TextEditingController();
  late Map<String, bool> dispositivosSelecionados;

  @override
  void initState() {
    super.initState();
    dispositivosSelecionados = {
      'Sala': false,
      'Cozinha': false,
      'Banheiro': false,
      'Quarto': false,
      'VentPrimeiroAndar': false,
      'VentSegundoAndar': false,
      'Portao': false,
    };
    if (widget.cenario != null) {
      nomeController.text = widget.cenario!.nome;
      for (var k in widget.cenario!.dispositivos.keys) {
        dispositivosSelecionados[k] = widget.cenario!.dispositivos[k] ?? false;
      }
    }
  }

  void _salvar() {
    if (nomeController.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Dê um nome para o cenário.")),
      );
      return;
    }
    if (!dispositivosSelecionados.values.any((v) => v)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Selecione pelo menos um dispositivo.")),
      );
      return;
    }
    widget.onSalvar(
      Cenario(
        nome: nomeController.text.trim(),
        dispositivos: Map.from(dispositivosSelecionados),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // helper local para rotular os dispositivos
    String label(String k) {
      switch (k) {
        case 'VentPrimeiroAndar':
          return 'Ventilação 1º andar';
        case 'VentSegundoAndar':
          return 'Ventilação 2º andar';
        default:
          return k;
      }
    }

    return Padding(
      padding: const EdgeInsets.all(20),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text("Cenário",
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
            TextField(
              controller: nomeController,
              decoration: const InputDecoration(labelText: 'Nome do Cenário'),
            ),
            const SizedBox(height: 12),

            // usa o helper para rotular cada item
            ...dispositivosSelecionados.keys.map((key) => CheckboxListTile(
                  title: Text(label(key)),
                  value: dispositivosSelecionados[key],
                  onChanged: (v) => setState(
                      () => dispositivosSelecionados[key] = v ?? false),
                )),

            const SizedBox(height: 20),
            ElevatedButton(
              onPressed: _salvar,
              child: const Text("Salvar Cenário"),
            ),
          ],
        ),
      ),
    );
  }
}

// ------------- LOGS PAGE (ADMIN) --------------
class DeviceLogsPage extends StatefulWidget {
  const DeviceLogsPage({super.key});

  @override
  State<DeviceLogsPage> createState() => _DeviceLogsPageState();
}

class _DeviceLogsPageState extends State<DeviceLogsPage> {
  // filtros
  String? _device; // ex: "Sala", "VentPrimeiroAndar"...
  String? _userUid; // uid do usuário
  DateTime? _from; // data inicial (00:00)
  DateTime? _to; // data final (23:59)

  static const _knownDevices = <String>[
    'Sala',
    'Cozinha',
    'Banheiro',
    'Quarto',
    'VentPrimeiroAndar',
    'VentSegundoAndar',
    'Portao',
  ];

  String _fmtDate(DateTime? d) {
    if (d == null) return 'Selecionar';
    return '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year}';
  }

  Future<void> _pickDate({required bool isFrom}) async {
    final initial = (isFrom ? _from : _to) ?? DateTime.now();
    final first = DateTime(2023, 1, 1);
    final last = DateTime.now().add(const Duration(days: 365));
    final picked = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: first,
      lastDate: last,
      helpText: isFrom ? 'Data inicial' : 'Data final',
    );
    if (picked != null) {
      setState(() {
        if (isFrom) {
          _from = DateTime(picked.year, picked.month, picked.day, 0, 0, 0);
        } else {
          _to =
              DateTime(picked.year, picked.month, picked.day, 23, 59, 59, 999);
        }
      });
    }
  }

  Query<Map<String, dynamic>> _buildQuery() {
    Query<Map<String, dynamic>> q =
        FirebaseFirestore.instance.collection('logs_dispositivos');

    if (_device != null && _device!.isNotEmpty) {
      q = q.where('dispositivo', isEqualTo: _device);
    }
    if (_userUid != null && _userUid!.isNotEmpty) {
      q = q.where('uid', isEqualTo: _userUid);
    }
    if (_from != null) {
      q = q.where('ts', isGreaterThanOrEqualTo: Timestamp.fromDate(_from!));
    }
    if (_to != null) {
      q = q.where('ts', isLessThanOrEqualTo: Timestamp.fromDate(_to!));
    }

    // range por ts exige orderBy(ts)
    q = q.orderBy('ts', descending: true).limit(500);
    return q;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: kGradientStart,
        title: const Text('Logs de Dispositivos'),
        actions: [
          IconButton(
            tooltip: 'Limpar filtros',
            icon: const Icon(Icons.filter_alt_off),
            onPressed: () => setState(() {
              _device = null;
              _userUid = null;
              _from = null;
              _to = null;
            }),
          ),
        ],
      ),
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            colors: [kGradientStart, kGradientEnd],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
        ),
        child: Column(
          children: [
            // --------- Barra de filtros ----------
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
              child: Column(
                children: [
                  Row(
                    children: [
                      // Dispositivo
                      Expanded(
                        child: DropdownButtonFormField<String?>(
                          value: _device,
                          isDense: true,
                          dropdownColor: const Color(0xFF222C36),
                          decoration: const InputDecoration(
                            labelText: 'Dispositivo',
                            filled: true,
                            fillColor: Colors.black26,
                            border: OutlineInputBorder(),
                          ),
                          items: [
                            const DropdownMenuItem<String?>(
                                value: null, child: Text('Todos')),
                            ..._knownDevices.map(
                              (d) => DropdownMenuItem<String?>(
                                  value: d, child: Text(d)),
                            ),
                          ],
                          onChanged: (v) => setState(() => _device = v),
                        ),
                      ),
                      const SizedBox(width: 10),
                      // Usuário (dropdown populado via stream de perfis)
                      Expanded(
                        child: StreamBuilder<List<PerfilUsuario>>(
                          stream: UserService.streamTodos(),
                          builder: (context, s) {
                            final itens = <DropdownMenuItem<String?>>[
                              const DropdownMenuItem(
                                value: null,
                                child: Text('Todos os usuários'),
                              ),
                            ];
                            final users = (s.data ?? []);
                            itens.addAll(users.map((u) => DropdownMenuItem(
                                  value: u.uid,
                                  child:
                                      Text(u.nome.isEmpty ? u.email : u.nome),
                                )));
                            return DropdownButtonFormField<String?>(
                              value: _userUid,
                              isDense: true,
                              dropdownColor: const Color(0xFF222C36),
                              decoration: const InputDecoration(
                                labelText: 'Usuário',
                                filled: true,
                                fillColor: Colors.black26,
                                border: OutlineInputBorder(),
                              ),
                              items: itens,
                              onChanged: (v) => setState(() => _userUid = v),
                            );
                          },
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: () => _pickDate(isFrom: true),
                          icon: const Icon(Icons.calendar_today, size: 18),
                          label: Text('De: ${_fmtDate(_from)}'),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: Colors.white,
                            side: const BorderSide(color: Colors.white24),
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: () => _pickDate(isFrom: false),
                          icon: const Icon(Icons.calendar_month, size: 18),
                          label: Text('Até: ${_fmtDate(_to)}'),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: Colors.white,
                            side: const BorderSide(color: Colors.white24),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const Divider(color: Colors.white12, height: 1),

            // --------- Lista de logs (stream com filtros) ----------
            Expanded(
              child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                stream: _buildQuery().snapshots(),
                builder: (context, snap) {
                  if (snap.connectionState == ConnectionState.waiting) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  final docs = snap.data?.docs ?? [];
                  if (docs.isEmpty) {
                    return const Center(
                      child: Text('Sem logs para os filtros selecionados',
                          style: TextStyle(color: Colors.white70)),
                    );
                  }
                  return ListView.separated(
                    itemCount: docs.length,
                    separatorBuilder: (_, __) =>
                        const Divider(color: Colors.white12, height: 1),
                    itemBuilder: (context, i) {
                      final d = docs[i].data();
                      final dispositivo = d['dispositivo'] ?? '';
                      final ligado = d['ligado'] == true;
                      final nome = d['nome'] ?? '';
                      final email = d['email'] ?? '';
                      final ts = (d['ts'] as Timestamp?)?.toDate();
                      final quando = ts != null
                          ? '${ts.day.toString().padLeft(2, '0')}/${ts.month.toString().padLeft(2, '0')} '
                              '${ts.hour.toString().padLeft(2, '0')}:${ts.minute.toString().padLeft(2, '0')}'
                          : '';

                      return ListTile(
                        title: Text(
                          '$dispositivo  •  ${ligado ? "Ligado" : "Desligado"}',
                          style: const TextStyle(color: Colors.white),
                        ),
                        subtitle: Text(
                          '$nome  •  $email  •  $quando',
                          style: const TextStyle(color: Colors.white60),
                        ),
                      );
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ------------- ADMIN USERS PAGE --------------
class AdminUsersPage extends StatefulWidget {
  const AdminUsersPage({super.key});

  @override
  State<AdminUsersPage> createState() => _AdminUsersPageState();
}

class _AdminUsersPageState extends State<AdminUsersPage> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: kGradientStart,
        title: const Text('Controle de Usuários'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: () => setState(() {}),
          ),
        ],
      ),
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
              colors: [kGradientStart, kGradientEnd],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight),
        ),
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(12),
              child: TextField(
                onChanged: (v) =>
                    setState(() => _query = v.trim().toLowerCase()),
                decoration: InputDecoration(
                  hintText: 'Buscar por nome ou e-mail...',
                  filled: true,
                  fillColor: Colors.black26,
                  prefixIcon: const Icon(Icons.search),
                  border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12)),
                ),
              ),
            ),
            Expanded(
              child: StreamBuilder<List<PerfilUsuario>>(
                stream: UserService.streamTodos(),
                builder: (context, snapshot) {
                  if (snapshot.connectionState == ConnectionState.waiting) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  final lista = (snapshot.data ?? []).where((p) {
                    if (_query.isEmpty) return true;
                    return p.nome.toLowerCase().contains(_query) ||
                        p.email.toLowerCase().contains(_query);
                  }).toList();

                  if (lista.isEmpty) {
                    return const Center(
                        child: Text('Nenhum usuário encontrado',
                            style: TextStyle(color: Colors.white70)));
                  }

                  return ListView.separated(
                    itemCount: lista.length,
                    separatorBuilder: (_, __) =>
                        const Divider(color: Colors.white12, height: 1),
                    itemBuilder: (_, i) {
                      final p = lista[i];
                      return ListTile(
                        title: Text(p.nome.isEmpty ? p.email : p.nome,
                            style: const TextStyle(color: Colors.white)),
                        subtitle: Text(
                            '${p.email}  •  ${p.role}  •  ${p.ativo ? "ativo" : "inativo"}',
                            style: const TextStyle(color: Colors.white60)),
                        trailing: Wrap(
                          crossAxisAlignment: WrapCrossAlignment.center,
                          spacing: 8,
                          children: [
                            // Trocar role
                            DropdownButtonHideUnderline(
                              child: DropdownButton<String>(
                                value: p.role,
                                dropdownColor: const Color(0xFF222C36),
                                items: const [
                                  DropdownMenuItem(
                                      value: 'user', child: Text('user')),
                                  DropdownMenuItem(
                                      value: 'admin', child: Text('admin')),
                                ],
                                onChanged: (v) async {
                                  if (v == null) return;
                                  await UserService.atualizarCampo(
                                      p.uid, {'role': v});
                                  if (!mounted) return;
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(
                                        content:
                                            Text('Role de ${p.email} → $v')),
                                  );
                                },
                              ),
                            ),
                            // Ativar/desativar
                            Switch(
                              value: p.ativo,
                              activeColor: kYellow,
                              onChanged: (v) async {
                                await UserService.atualizarCampo(
                                    p.uid, {'ativo': v});
                                if (!mounted) return;
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(
                                      content: Text(v
                                          ? 'Conta ativada'
                                          : 'Conta desativada')),
                                );
                              },
                            ),
                            // Reset de senha
                            IconButton(
                              tooltip: 'Enviar e-mail de redefinição de senha',
                              icon: const Icon(Icons.lock_reset,
                                  color: Colors.orangeAccent),
                              onPressed: () async {
                                try {
                                  await FirebaseAuth.instance
                                      .sendPasswordResetEmail(email: p.email);
                                  if (!mounted) return;
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(
                                        content: Text(
                                            'Reset de senha enviado para ${p.email}')),
                                  );
                                } catch (e) {
                                  if (!mounted) return;
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(content: Text('Erro: $e')),
                                  );
                                }
                              },
                            ),
                            // Exclusão via Cloud Function
                            IconButton(
                              tooltip: 'Excluir conta',
                              icon: const Icon(Icons.delete_forever,
                                  color: Colors.redAccent),
                              onPressed: () async {
                                final ok = await showDialog<bool>(
                                  context: context,
                                  builder: (_) => AlertDialog(
                                    title: const Text('Excluir usuário?'),
                                    content: Text(
                                        'Isso excluirá permanentemente a conta de ${p.email}. Esta ação é irreversível.'),
                                    actions: [
                                      TextButton(
                                          onPressed: () =>
                                              Navigator.pop(context, false),
                                          child: const Text('Cancelar')),
                                      TextButton(
                                          onPressed: () =>
                                              Navigator.pop(context, true),
                                          child: const Text('Excluir')),
                                    ],
                                  ),
                                );
                                if (ok != true) return;

                                try {
                                  final callable = FirebaseFunctions.instance
                                      .httpsCallable('adminDeleteUser');
                                  await callable
                                      .call(<String, dynamic>{'uid': p.uid});

                                  // Remove o documento de perfil para “sumir” da lista
                                  await FirebaseFirestore.instance
                                      .collection('usuarios')
                                      .doc(p.uid)
                                      .delete();

                                  if (!mounted) return;
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    const SnackBar(
                                        content: Text(
                                            'Usuário excluído com sucesso')),
                                  );
                                } on FirebaseFunctionsException catch (e) {
                                  if (!mounted) return;
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(
                                        content: Text(
                                            'Erro: ${e.message ?? e.code}')),
                                  );
                                } catch (e) {
                                  if (!mounted) return;
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(
                                        content: Text('Erro ao excluir: $e')),
                                  );
                                }
                              },
                            ),
                          ],
                        ),
                      );
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
