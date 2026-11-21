# App Store listing: Creatica Chess Analyzer 1.0

Languages: English, Spanish, French, German, Russian.
Limits: name and subtitle 30 characters, promotional text 170, keywords 100 bytes (UTF-8: accented letters count 2), description 4,000.
Everything below is within them (checked with `notes/check-listing.py`). The app's own text is English in 1.0; the other languages'
descriptions say so.

iPhone and iPad, one app (bundle ID `org.creatica.chess-analyzer`). No Mac version in 1.0: iPad apps can run on Apple silicon Macs; leave
"Make this app available" on or off in Pricing and Availability › iPhone and iPad Apps on Apple Silicon Macs (on is harmless: it runs as on iPad).

Honest about real boards: printed games and diagrams read reliably; real 3D boards vary with the set, the light and the angle. Every language
says so in the description, the website says so, and the screenshot captions don't overclaim.

---

## App information (once)
- **Name:** Creatica Chess Analyzer (see "Name" below for why not plain "Chess Analyzer"). The home screen shows "Chess Analyzer"
  (`CFBundleDisplayName`), which needn't be unique.
- **Subtitle:** see each language below
- **Bundle ID / SKU:** org.creatica.chess-analyzer / chess-analyzer
- **Primary category:** Games › Board · **Secondary:** Education
  (the app is a chess tool, not a game you play against it; Board is where chess players look. Utilities is the alternative if review objects.)
- **Content rights:** No third-party content that needs rights: the engine is free software (GPL-3, Stockfish's NNUE evaluation, credited in
  Settings › About), the models were trained on our own renders and our own videos, and the screenshots show only our own boards and a public-domain
  game (Morphy, Paris 1858).
- **Age rating:** answer "None" / "No" to everything (no web browsing, no user-generated content shared with others, no ads, no purchases) → 4+

### Name
- "Chess Analyzer" alone is free as an exact name today, but "Chess Analyzer 24/7" and "Chess Analyzer: Raise Your Elo" exist, and a name
  that close is easy to confuse and may be refused as too generic.
- **Creatica Chess Analyzer** (23 characters) is distinct, matches your Windows program and website (Creatica Chess Game Analyzer,
  chessgame-analyzer.creatica.org) and the bundle ID's registered name, and still puts "Chess Analyzer" in the search name.
- If App Store Connect says it's taken: **Chess Analyzer by Creatica** (27).
- Not **Chess Analyzer Live** (free as a name, but): in chess app names "Live" means playing online or following live tournaments
  ("Chess Live Online", "Chess Time Live", "ChessEver: Follow Live Chess"), which this app doesn't do, and it headlines the live camera,
  the feature whose results vary. "Live camera" fits the description and keywords instead.

## Pricing and availability
- **Recommended price: US$4.99 one-off** (tier shown locally as A$7.99, €5.99, £4.99), no in-app purchases, no subscription.
  - Comparable one-off engine apps: SmallFish (analysis with Stockfish) A$7.99, Chess Tiger Pro A$9.99, tChess Pro A$12.99, Shredder A$14.99.
    The scanning apps (Chessvision.ai, Chessify) are free downloads with subscriptions; "Chess Analyzer: Raise Your Elo" is A$4.99.
  - One price, no subscription, is a selling point against the scanners, and the reliable core (game analysis, printed games, diagrams) is
    worth it on its own; the description is honest that real boards vary, which keeps refunds and one-star reviews down.
  - Alternative: free, as your Windows program was. More downloads and ratings early, which help a new name be found; you could charge
    from 1.1. The GPL allows either (the source is public either way).
- **Availability:** all countries.
- **Small Business Program:** already enrolled for your other apps? It applies to the whole account (15% commission).

## App privacy
- **Privacy policy URL:** https://chessgame-analyzer.creatica.org/ios/privacy.html
- **Data collection:** "No, we do not collect data from this app" → **Data Not Collected**. The app makes no network connections at all.
  `PrivacyInfo.xcprivacy` is included (UserDefaults for settings; file timestamps in the app's container, by the engine).
- **Export compliance:** answered by the build (`ITSAppUsesNonExemptEncryption` = NO: the app uses no encryption).

## Version 1.0
- **Support URL:** https://chessgame-analyzer.creatica.org/ios/support.html
- **Marketing URL:** https://chessgame-analyzer.creatica.org/ios/
- **Copyright:** 2026 Creatica
- **Version / build:** 1.0 (1), set in project.yml (`MARKETING_VERSION`, `CURRENT_PROJECT_VERSION`); raise the build number for every upload.
- **Sign-in required:** No
- **Contact (only Apple's reviewers see it):** your name, phone and email

---

## Screenshots

Sizes App Store Connect needs (larger devices are scaled down for the smaller ones):
- **iPhone ("iPhone with Dynamic Island, medium display", 6.1"/6.3"):** 1206 × 2622 portrait. `stage.py` captures on the iPhone 18 Pro Max
  and resizes to 1206 × 2622 RGB in "iPhone 6.3 (1206x2622) - upload these".
- **iPad 13":** 2064 × 2752 portrait (iPad Pro 13-inch (M5) simulator), in "iPad 13 (2064x2752) - upload these".

Made by `tools/screenshots/stage.py` (see its docstring): `--device "iPhone 18 Pro Max"`, `--device "iPad Pro 13-inch (M5)"`, then
`--upload`. Upload-ready copies are in ~/Documents/ChessAnalyzer-Screenshots/*- upload these/. The scenes, in order, with caption ideas
(if you add captions in a design tool; App Store Connect itself shows the screenshots plain):

1. **An analysed game** (Morphy's Opera Game): moves marked, the evaluation graph, the better move's arrow. "Find every mistake".
2. **The better line**, played through on the board. "See the move you should have played".
3. **A diagram read onto the board** and analysed. "Photograph a diagram, analyse the position".
4. **A printed game read** from a scanned page, guesses marked. "Read games from books and magazines".
5. **A real board read from a photo** (the wooden set). "Photograph a board on the table".

The live camera isn't a scene: in the simulator it settles within seconds, too fast to catch it reading, and its result looks like
scene 5. A photo of the live camera on a real board, taken on your phone, could be added later.

---

## App Review notes

Chess Analyzer analyses chess games and positions with a chess engine that runs on the device. No account or sign-in is needed, and the
app makes no network connections.

How to test:
1. Games: copy this game, tap the Paste button (top right, beside +), then tap Analyze Game. (Or + › Type PGN… and paste it there.) Each move is marked as an inaccuracy, mistake or
   blunder, and the arrow shows the engine's better move.

       [Event "Paris"] [White "Paul Morphy"] [Black "Duke Karl / Count Isouard"] [Result "1-0"]
       1. e4 e5 2. Nf3 d6 3. d4 Bg4 4. dxe5 Bxf3 5. Qxf3 dxe5 6. Bc4 Nf6 7. Qb3 Qe7 8. Nc3 c6 9. Bg5 b5
       10. Nxb5 cxb5 11. Bxb5+ Nbd7 12. O-O-O Rd8 13. Rxd7 Rxd7 14. Rd1 Qe6 15. Bxd7+ Nxd7 16. Qb8+ Nxb8 17. Rd8# 1-0

2. Position: the engine analyses the position on the board. The ⋯ menu › Read a Diagram › Choose Photo… reads a chess diagram from a picture;
   sample pictures (a book diagram, a printed game, a photo of a real board) are at https://chessgame-analyzer.creatica.org/ios/samples/
   (in Safari, touch and hold an image › Save to Photos).
3. Games › + › Scan with Camera… reads a printed game from a page (the sample "printed game" picture works from + › Choose Photo… too).
4. Position › ⋯ › Read a Real Board › Live Camera…, Take Photo… or Choose Photo… reads a physical chess board (the sample board photo works
   with Choose Photo…). The camera is used only for this, and only on the device.

The engine (Creatica AB) is free software under the GNU GPL v3; Settings › About links to its source and the app's.

---

## English

### Subtitle
Analyze games, read diagrams

### Promotional text
A strong chess engine on your iPhone and iPad: find your mistakes, see the better move, and bring in games from print and positions from diagrams. No ads, no account.

### Keywords
pgn,fen,engine,diagram,scanner,blunder,annotate,analysis,position,board,camera,review,study,coach

### Description
Chess Analyzer finds the mistakes in your games. A strong chess engine runs on your iPhone or iPad, marks every inaccuracy, mistake and blunder, and shows you the move you should have played. Bring games in from PGN, from printed pages, and positions from diagrams or a board on the table.

ANALYSE YOUR GAMES
• Analyze Game searches every position and marks each move by what it loses against the engine's best move
• An arrow on the board shows the better move; play through the engine's line
• Evaluation graph across the game, and a summary per player with average loss
• Your own limits for inaccuracies, mistakes and blunders, and how long the engine thinks
• Share the game as annotated PGN: evaluations, symbols, and the better moves as variations

ANALYSE ANY POSITION
• Set up a position, paste a FEN, or jump in from any move of a game
• Score, best move and the main line, updating as the engine searches deeper

BRING GAMES AND POSITIONS IN
• Open PGN files from Files, Mail or the share sheet, or paste or type a game
• Printed games: scan a book or magazine page, or use a photo or screenshot. The moves are found by their numbers and checked against the rules, so two columns and commentary don't get in the way; any guess is shown for you to confirm
• Diagrams: photograph or screenshot a diagram and the position appears on the board
• Real boards: take a photo of a board on the table, or use the live camera

Printed games and diagrams read reliably. Reading a real board is newer and its results vary with the chess set, the light and the angle: it works best with a Staunton set seen from White's side and from above. Every square can be corrected and the board's corners set by hand, and it improves with each update.

PRIVATE
No account, no ads, no analytics, no tracking. The app doesn't use the internet: your games and photos stay on your device.

FREE SOFTWARE
The engine, Creatica AB, uses Stockfish's NNUE evaluation. The app is licensed under the GNU GPL v3, and its source code is public.

---

## Español

### Name
Creatica Chess Analyzer

### Subtitle
Analiza partidas y diagramas

### Promotional text
Un motor de ajedrez potente en su iPhone y iPad: encuentre sus errores, vea la mejor jugada y lea partidas impresas y diagramas. Sin anuncios y sin cuenta.

### Keywords
ajedrez,pgn,fen,motor,diagrama,escáner,análisis,posición,tablero,cámara,error,estudio,entrenador

### Description
Chess Analyzer encuentra los errores de sus partidas. Un motor de ajedrez potente funciona en su iPhone o iPad, marca cada imprecisión, error y error grave, y le muestra la jugada que debió hacer. Importe partidas en PGN o de páginas impresas, y posiciones de diagramas o de un tablero real.

Nota: la app está en inglés.

ANALICE SUS PARTIDAS
• Analyze Game examina cada posición y marca cada jugada según lo que pierde frente a la mejor jugada del motor
• Una flecha en el tablero muestra la mejor jugada; reproduzca la variante del motor
• Gráfico de evaluación de toda la partida y un resumen por jugador con la pérdida media
• Sus propios límites para imprecisiones, errores y errores graves, y cuánto piensa el motor
• Comparta la partida como PGN anotado: evaluaciones, símbolos y las mejores jugadas como variantes

ANALICE CUALQUIER POSICIÓN
• Coloque una posición, pegue un FEN o entre desde cualquier jugada de una partida
• Evaluación, mejor jugada y variante principal, que se actualizan mientras el motor profundiza

IMPORTE PARTIDAS Y POSICIONES
• Abra archivos PGN desde Archivos, Mail o el menú Compartir, o pegue o escriba una partida
• Partidas impresas: escanee una página de un libro o revista, o use una foto o captura de pantalla. Las jugadas se localizan por su número y se comprueban con las reglas, así que las dos columnas y los comentarios no molestan; cada jugada adivinada se le muestra para que la confirme
• Diagramas: fotografíe o capture un diagrama y la posición aparece en el tablero
• Tableros reales: haga una foto de un tablero sobre la mesa o use la cámara en directo

Las partidas impresas y los diagramas se leen de forma fiable. La lectura de un tablero real es más reciente y sus resultados varían según el juego de piezas, la luz y el ángulo: funciona mejor con piezas Staunton, vistas desde el lado de las blancas y desde arriba. Cada casilla puede corregirse y las esquinas del tablero pueden marcarse a mano, y mejora con cada actualización.

PRIVACIDAD
Sin cuenta, sin anuncios, sin análisis, sin rastreo. La app no usa internet: sus partidas y fotos se quedan en su dispositivo.

SOFTWARE LIBRE
El motor, Creatica AB, usa la evaluación NNUE de Stockfish. La app tiene licencia GNU GPL v3 y su código fuente es público.

---

## Français

### Name
Creatica Chess Analyzer

### Subtitle
Analyse de parties, diagrammes

### Promotional text
Un moteur d'échecs puissant sur iPhone et iPad : trouvez vos erreurs, voyez le meilleur coup, et lisez parties imprimées et diagrammes. Sans pub, sans compte.

### Keywords
échecs,pgn,fen,moteur,diagramme,scanner,analyse,position,échiquier,caméra,gaffe,entraîneur

### Description
Chess Analyzer trouve les erreurs de vos parties. Un moteur d'échecs puissant tourne sur votre iPhone ou iPad, signale chaque imprécision, erreur et gaffe, et vous montre le coup qu'il fallait jouer. Importez des parties en PGN ou depuis des pages imprimées, et des positions depuis des diagrammes ou un vrai échiquier.

À noter : l'application est en anglais.

ANALYSEZ VOS PARTIES
• Analyze Game examine chaque position et évalue chaque coup par ce qu'il perd face au meilleur coup du moteur
• Une flèche sur l'échiquier montre le meilleur coup ; rejouez la variante du moteur
• Courbe d'évaluation de la partie, et un bilan par joueur avec la perte moyenne
• Vos propres seuils pour les imprécisions, erreurs et gaffes, et le temps de réflexion du moteur
• Partagez la partie en PGN annoté : évaluations, symboles, et les meilleurs coups en variantes

ANALYSEZ N'IMPORTE QUELLE POSITION
• Placez une position, collez un FEN, ou partez de n'importe quel coup d'une partie
• Évaluation, meilleur coup et variante principale, mis à jour à mesure que le moteur approfondit

IMPORTEZ PARTIES ET POSITIONS
• Ouvrez des fichiers PGN depuis Fichiers, Mail ou le menu Partager, ou collez ou tapez une partie
• Parties imprimées : scannez une page de livre ou de revue, ou utilisez une photo ou une capture d'écran. Les coups sont repérés par leur numéro et vérifiés selon les règles, si bien que les deux colonnes et les commentaires ne gênent pas ; chaque coup deviné vous est montré pour confirmation
• Diagrammes : photographiez ou capturez un diagramme et la position apparaît sur l'échiquier
• Vrais échiquiers : prenez en photo un échiquier sur la table, ou utilisez la caméra en direct

Les parties imprimées et les diagrammes se lisent de façon fiable. La lecture d'un vrai échiquier est plus récente et ses résultats varient selon le jeu de pièces, la lumière et l'angle : elle marche le mieux avec des pièces Staunton vues du côté des Blancs et d'en haut. Chaque case peut être corrigée et les coins de l'échiquier placés à la main, et elle s'améliore à chaque mise à jour.

CONFIDENTIALITÉ
Sans compte, sans publicité, sans analyse, sans pistage. L'application n'utilise pas internet : vos parties et vos photos restent sur votre appareil.

LOGICIEL LIBRE
Le moteur, Creatica AB, utilise l'évaluation NNUE de Stockfish. L'application est sous licence GNU GPL v3 et son code source est public.

---

## Deutsch

### Name
Creatica Chess Analyzer

### Subtitle
Partien analysieren, Diagramme

### Promotional text
Eine starke Schach-Engine auf iPhone und iPad: Fehler finden, den besseren Zug sehen, Partien aus Büchern und Stellungen aus Diagrammen einlesen. Ohne Werbung und Konto.

### Keywords
schach,pgn,fen,engine,diagramm,scanner,analyse,stellung,brett,kamera,fehler,training,studie

### Description
Chess Analyzer findet die Fehler in Ihren Partien. Eine starke Schach-Engine läuft auf Ihrem iPhone oder iPad, markiert jede Ungenauigkeit, jeden Fehler und jeden groben Fehler und zeigt Ihnen den Zug, den Sie hätten spielen sollen. Partien kommen aus PGN-Dateien oder gedruckten Seiten, Stellungen aus Diagrammen oder von einem echten Brett.

Hinweis: Die App selbst ist auf Englisch.

PARTIEN ANALYSIEREN
• Analyze Game untersucht jede Stellung und bewertet jeden Zug danach, was er gegenüber dem besten Zug der Engine verliert
• Ein Pfeil auf dem Brett zeigt den besseren Zug; spielen Sie die Variante der Engine nach
• Bewertungskurve über die ganze Partie und eine Übersicht je Spieler mit dem durchschnittlichen Verlust
• Eigene Grenzen für Ungenauigkeiten, Fehler und grobe Fehler, und wie lange die Engine rechnet
• Die Partie als kommentiertes PGN teilen: Bewertungen, Symbole und die besseren Züge als Varianten

JEDE STELLUNG ANALYSIEREN
• Stellung aufbauen, FEN einfügen oder von jedem Zug einer Partie aus einsteigen
• Bewertung, bester Zug und Hauptvariante, laufend aktualisiert, während die Engine tiefer rechnet

PARTIEN UND STELLUNGEN EINLESEN
• PGN-Dateien aus Dateien, Mail oder dem Teilen-Menü öffnen, oder eine Partie einfügen oder eintippen
• Gedruckte Partien: eine Buch- oder Zeitschriftenseite scannen, oder ein Foto oder Bildschirmfoto verwenden. Die Züge werden an ihren Nummern erkannt und nach den Regeln geprüft, so stören zwei Spalten und Kommentare nicht; jeder geratene Zug wird Ihnen zur Bestätigung gezeigt
• Diagramme: ein Diagramm fotografieren oder als Bildschirmfoto aufnehmen, und die Stellung steht auf dem Brett
• Echte Bretter: ein Brett auf dem Tisch fotografieren oder die Live-Kamera verwenden

Gedruckte Partien und Diagramme werden zuverlässig gelesen. Das Lesen eines echten Bretts ist neuer, und die Ergebnisse hängen von den Figuren, dem Licht und dem Blickwinkel ab: Am besten gelingt es mit Staunton-Figuren, von der weißen Seite und von oben gesehen. Jedes Feld lässt sich korrigieren und die Brettecken lassen sich von Hand setzen, und es wird mit jedem Update besser.

PRIVATSPHÄRE
Kein Konto, keine Werbung, keine Analyse, kein Tracking. Die App nutzt das Internet nicht: Ihre Partien und Fotos bleiben auf Ihrem Gerät.

FREIE SOFTWARE
Die Engine, Creatica AB, nutzt die NNUE-Bewertung von Stockfish. Die App steht unter der GNU GPL v3, ihr Quellcode ist öffentlich.

---

## Русский

### Name
Creatica Chess Analyzer

### Subtitle
Анализ партий и диаграмм

### Promotional text
Сильный шахматный движок на iPhone и iPad: найдите свои ошибки, увидьте лучший ход, загрузите партии из книг и позиции с диаграмм. Без рекламы и без аккаунта.

### Keywords
шахматы,pgn,fen,движок,диаграмма,анализ,доска,сканер

### Description
Chess Analyzer находит ошибки в ваших партиях. Сильный шахматный движок работает прямо на iPhone или iPad, отмечает каждую неточность, ошибку и грубую ошибку и показывает ход, который следовало сделать. Партии можно загрузить из PGN или с печатных страниц, а позиции — с диаграмм или с настоящей доски.

Примечание: приложение на английском языке.

АНАЛИЗ ПАРТИЙ
• Analyze Game проверяет каждую позицию и оценивает каждый ход по тому, сколько он теряет по сравнению с лучшим ходом движка
• Стрелка на доске показывает лучший ход; вариант движка можно проиграть на доске
• График оценки по всей партии и итоги по каждому игроку со средней потерей
• Свои пороги для неточностей, ошибок и грубых ошибок, и сколько думает движок
• Партию можно отправить как PGN с комментариями: оценки, символы и лучшие ходы в виде вариантов

АНАЛИЗ ЛЮБОЙ ПОЗИЦИИ
• Расставьте позицию, вставьте FEN или перейдите к любому ходу партии
• Оценка, лучший ход и главный вариант, обновляемые по мере углубления расчёта

ЗАГРУЗКА ПАРТИЙ И ПОЗИЦИЙ
• Файлы PGN из «Файлов», Почты или меню «Поделиться»; партию можно также вставить или набрать
• Печатные партии: отсканируйте страницу книги или журнала либо используйте фото или снимок экрана. Ходы находятся по номерам и проверяются по правилам, поэтому две колонки и комментарии не мешают; каждый угаданный ход показывается вам для проверки
• Диаграммы: сфотографируйте диаграмму или сделайте снимок экрана — и позиция появится на доске
• Настоящие доски: сфотографируйте доску на столе или используйте камеру в реальном времени

Печатные партии и диаграммы распознаются надёжно. Распознавание настоящей доски — более новая функция, и результат зависит от комплекта фигур, освещения и ракурса: лучше всего с фигурами Стаунтона, если смотреть со стороны белых и сверху. Любое поле можно исправить, углы доски можно задать вручную, и распознавание улучшается с каждым обновлением.

КОНФИДЕНЦИАЛЬНОСТЬ
Без аккаунта, без рекламы, без аналитики, без отслеживания. Приложение не пользуется интернетом: ваши партии и фото остаются на вашем устройстве.

СВОБОДНОЕ ПО
Движок Creatica AB использует оценку NNUE от Stockfish. Приложение распространяется по лицензии GNU GPL v3, его исходный код открыт.
