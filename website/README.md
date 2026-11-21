# chessgame-analyzer.creatica.org/ios/

Static pages for the App Store listing of Chess Analyzer for iPhone and iPad, in their own folder next to the Windows
program's pages: `ios/index.html` (marketing URL), `ios/support.html` (support URL), `ios/privacy.html` (privacy policy URL),
`ios/samples/` (pictures App Review and users can try the app with), `ios/style.css`, `ios/images/`. No scripts, web fonts,
cookies or outside resources.

Upload the `ios` folder as it is to the site's web root, so the pages are at https://chessgame-analyzer.creatica.org/ios/.
The site's home page (index.html, and index-ru.html) needs a link to it, for example in the Contents box:

    <a href="ios/" tabindex="0">iPhone &amp; iPad app</a><hr />

Before publishing: check that chessgame-analyzer@creatica.org is read, and update the privacy policy's date whenever the app
gains a feature that stores or sends anything new. The screenshots in `ios/images/` come from tools/screenshots/stage.py.
