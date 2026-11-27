# Changelog

## [1.2.2](https://github.com/johnstonmatt/lockin/compare/v1.2.1...v1.2.2) (2026-11-27)


### Bug Fixes

* allow sessions to start before choosing work ([6997d66](https://github.com/johnstonmatt/lockin/commit/6997d664b5d0984fb11eac3a60fe8fe2bea04f11))

## [1.2.1](https://github.com/johnstonmatt/lockin/compare/v1.2.0...v1.2.1) (2026-11-26)


### Bug Fixes

* mark mergeable unstable PRs ready when required checks pass ([5618913](https://github.com/johnstonmatt/lockin/commit/5618913fa4d1bdc0edac52d45a7a7a4cf7d7f612))


### Documentation

* move development and release instructions to CONTRIBUTING.md ([c574e11](https://github.com/johnstonmatt/lockin/commit/c574e1158184223710f0afaa2be1e7ac7ccc72bf))
* reorganize README around setup and daily use ([7fa113a](https://github.com/johnstonmatt/lockin/commit/7fa113a25cc46b5cf4017dbf494c2a7643f96517))

## [1.2.0](https://github.com/johnstonmatt/lockin/compare/v1.1.0...v1.2.0) (2026-11-26)


### Features

* **work:** add persistent source-owned graphs and provider imports ([1cd86d4](https://github.com/johnstonmatt/lockin/commit/1cd86d484fe227c9ec41eeb79557f9545788867f))
* **work:** integrate focused session selections and unified entry form ([e62f26b](https://github.com/johnstonmatt/lockin/commit/e62f26b05c7a64e731c9078049f3da2a3026487e))
* **work:** render dependency graphs and nested work lists ([895b048](https://github.com/johnstonmatt/lockin/commit/895b0480960035f3108929b10e9041354e7ac05f))


### Refactoring

* remove unused task form and link badge views ([4c464cb](https://github.com/johnstonmatt/lockin/commit/4c464cb7324b7f67833c14923c06e29ce1e3dc7a))
* remove unused task link labels ([676d530](https://github.com/johnstonmatt/lockin/commit/676d530ab74a31d6d044e0ea5a063e97c469f35e))
* **work:** compute graph reachability from adjacency maps ([b3b2c24](https://github.com/johnstonmatt/lockin/commit/b3b2c24a3c016c4222df5de1954a683ea9f02ea7))
* **work:** derive session context and region summaries once per presentation ([8ded1c4](https://github.com/johnstonmatt/lockin/commit/8ded1c41e0875636d01e7605bf36a5e8955512b3))
* **work:** match duplicate work with one predicate ([7362611](https://github.com/johnstonmatt/lockin/commit/736261153853b780a52c63d4e3975c782aabbef8))
* **work:** remove task-level dependency sequencing ([9f81617](https://github.com/johnstonmatt/lockin/commit/9f81617e9227f6d92e21619433d2c4ee0bda1e22))
* **work:** share layout and routing helpers ([144fbaa](https://github.com/johnstonmatt/lockin/commit/144fbaa20030f79d2563ae216228734fd85196f4))
* **work:** type work display status and share PR node IDs ([7b436e9](https://github.com/johnstonmatt/lockin/commit/7b436e90f88c1c41176161f6043f5d6f60f3b557))


### Documentation

* **work:** describe source-owned graphs and session workflows ([db94659](https://github.com/johnstonmatt/lockin/commit/db94659d18bcf0ad659ed71c15d8c1735d75c4fb))

## [1.1.0](https://github.com/johnstonmatt/lockin/compare/v1.0.0...v1.1.0) (2026-11-17)


### Features

* add check for updates controls to the app ([8fd7e7e](https://github.com/johnstonmatt/lockin/commit/8fd7e7e101c11371d9b61865cb07381e01b49033))
* add Return submission and Escape cancellation to session dialogs ([fc0189d](https://github.com/johnstonmatt/lockin/commit/fc0189d2ca6c4c154be81369c883b2b1ba69b984))

## [1.0.0](https://github.com/johnstonmatt/lockin/compare/v0.4.0...v1.0.0) (2026-11-04)


### Features

* migrate journals to schema-defined JSON files and add session events ([75b81f4](https://github.com/johnstonmatt/lockin/commit/75b81f41b5271b6a9ee5bd51cf725bb8cd85d6b1))
* show session events in timelines and CLI status ([c550f1c](https://github.com/johnstonmatt/lockin/commit/c550f1cc94da577948ca576056b4f98afc0b8156))


### Refactoring

* consolidate shared session, workflow, and CLI helpers ([c84c23b](https://github.com/johnstonmatt/lockin/commit/c84c23bdd93f95daf7ac4090371d8ee95ad3402d))


### Documentation

* correct README architecture and hooks notes, explain release versioning ([6d02af0](https://github.com/johnstonmatt/lockin/commit/6d02af09cf8453330577cf732bd4985db3cd5ae2))

## [0.4.0](https://github.com/johnstonmatt/lockin/compare/v0.3.0...v0.4.0) (2026-11-04)


### Features

* add an Install CLI button to Settings ([b471c1c](https://github.com/johnstonmatt/lockin/commit/b471c1ccba8ad1409b541bc85522bcdd28e8cea2))
* add the lockin command line tool ([892a2d0](https://github.com/johnstonmatt/lockin/commit/892a2d0b07972eb6527a141db9e1221df0943ace))
* resume automatically when the Mac wakes ([fbaf1af](https://github.com/johnstonmatt/lockin/commit/fbaf1af157f9b5445489b947a91c6bbb898aac02))


### Refactoring

* rename Insights to History ([84bf9e1](https://github.com/johnstonmatt/lockin/commit/84bf9e18ea3a0be9eb82da0fa5de5a9a3bb85dd0))


### Documentation

* remove Focus comparisons and clarify release token permissions ([1586207](https://github.com/johnstonmatt/lockin/commit/1586207ea5e160d3a3b90cd5c071ae8423a3bb7d))

## [0.3.0](https://github.com/johnstonmatt/lockin/compare/v0.2.0...v0.3.0) (2026-11-03)


### Features

* allow toggling task completion during active sessions ([1dee525](https://github.com/johnstonmatt/lockin/commit/1dee525f443614012f94115774d78677ff77d7cd))
* track overtime after work targets and allow explicit session completion ([b20596e](https://github.com/johnstonmatt/lockin/commit/b20596ebc3b9ba9518634c4e3e33b6add5ade00d))


### Refactoring

* remove scheduling and legacy records, streamline task forms and journal persistence ([bb1d4af](https://github.com/johnstonmatt/lockin/commit/bb1d4af5581ef8c0e4fcda46d814ca4b6f8d516e))

## [0.2.0](https://github.com/johnstonmatt/lockin/compare/v0.1.0...v0.2.0) (2026-11-03)


### Features

* allow deleting tasks during active sessions ([586a93d](https://github.com/johnstonmatt/lockin/commit/586a93d63ee71aa2472093c14ab89a012b4ecda5))
* support general task links and pointing-hand button cursors ([06c0f8d](https://github.com/johnstonmatt/lockin/commit/06c0f8d07325eee0e6cbcfe85fc04a242307c046))

## 0.1.0 (2026-11-03)


### Features

* add native macOS focus app with distraction blocking, session journals, and insights ([fce91f9](https://github.com/johnstonmatt/lockin/commit/fce91f9b93e92aae75bd016940ed4861bca5ea55))
* allow adding tasks during active sessions ([d502802](https://github.com/johnstonmatt/lockin/commit/d502802110a4439734348a9546b5c60fa9697d75))
* first release ([73cc8b4](https://github.com/johnstonmatt/lockin/commit/73cc8b4033a54b7f90113b29ccc5acbb88cbefa4))
* **release:** prepare first signed macos release ([7018aaa](https://github.com/johnstonmatt/lockin/commit/7018aaa29f01ee750786cb0db34635c593446fdc))
* resume sessions after updates, edit active tasks, and return to blocked URLs on refresh ([14ef00c](https://github.com/johnstonmatt/lockin/commit/14ef00c654e77b4d67e9a4c042feb95118e23a36))
* **ui:** unify text input styling with focus and validation rings ([001d5a4](https://github.com/johnstonmatt/lockin/commit/001d5a490337587b3cbc3103296eb144d52e9a9c))


### Refactoring

* centralize session timing in WorkLog and remove legacy modes ([3c414c9](https://github.com/johnstonmatt/lockin/commit/3c414c98b465a5d925149738896557d884aca24f))
