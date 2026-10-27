# Orizon

Lecteur iOS pour les scans VF d'[Aniverse](https://aniverse.fr), installable avec AltStore.

## Fonctions

- Accueil : sorties récentes, populaires, nouveautés, reprise de lecture
- Recherche par titre, tri et genres
- Fiche manga avec la liste complète des chapitres
- Lecteur vertical (webtoon) qui enchaîne automatiquement sur le chapitre suivant
- Bibliothèque, progression de lecture, chapitres lus
- Nouveaux chapitres des mangas suivis (badge)
- Téléchargements rapides (plusieurs chapitres et pages en parallèle) pour lire hors ligne

## Installer

Chaque push sur `main` compile l'appli avec GitHub Actions et publie `Orizon.ipa` dans la
release [`latest`](../../releases/tag/latest). Télécharge le fichier sur l'iPhone puis
ouvre-le avec AltStore (« + » → choisir le fichier).

## Développer

Le projet Xcode est généré par [XcodeGen](https://github.com/yonaskolb/XcodeGen) :

```sh
brew install xcodegen
xcodegen generate
open Orizon.xcodeproj
```
