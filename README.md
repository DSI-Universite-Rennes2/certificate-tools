# Gestion des certificats 

[![reuse compliant](https://reuse.software/badge/reuse-compliant.svg)](https://reuse.software/) 
[![Trigger: Shell Check](https://github.com/DSI-Universite-Rennes2/certificate-tools/actions/workflows/main.yml/badge.svg?event=push)](https://github.com/DSI-Universite-Rennes2/certificate-tools/actions/workflows/main.yml)
[![License: GPL v3](https://img.shields.io/badge/License-GPLv3-blue.svg)](https://www.gnu.org/licenses/gpl-3.0)

Cet outils permet la gestion et l'organisation des certificats sur un serveur. Il vous permet en retour d'avoir un chemin fixe vers la partie la plus récente qui vous intéresse :

* le certificat seul,
* le certificat avec le certificat de l'autorité intermédiaire,
* le certificat de l'autorité intermédiaire,
* la clé privée.

Quelque soit l'ordre des éléments dans le certificats importé l'outil se charge de le trouver et de reconstuire la chaine de certification.

## Installation

```bash
cd /applis
git clone https://github.com/DSI-Universite-Rennes2/certificate-tools.git

# Si vous avez des certificats apache existant vous pouvez les installer :
cd certificate-tools
./cert.sh -i /etc/apache2/certs
```

## Usage

Condition pour importer vos certificats :

* même base de nom pour le certificat et la clé
* extension pem pour le certificat,
* extension key pour la clé dans le même répertoire ou dans un sous répertoire `private/`,

Exemple :

* `toto.pem` pour le certificat,
* `toto.key` pour la clé.

**NOTE**

* les certificats expirés ne sont pas importés.
* n'importez pas vous même les certificats dans les répertoires archive ou live !

Copiez le certificat et sa clé dans un répertoire (/tmp, votre homedir ..) puis importer les dans l'outil :

```bash
/applis/certificate-tools/cert.sh -i /tmp
```

Vous pouvez ensuite atteindre pour chaque FQDN référencé en principal ou alternatif dans le certificat avec un chemin fixe :

* Clé privée : `/applis/certificate-tools/live/toto.univ-rennes2.fr/privkey.pem`
* Certificat seul : `/applis/certificate-tools/live/toto.univ-rennes2.fr/cert.pem`
* Certificat + certificat intermédiaire : `/applis/certificate-tools/live/toto.univ-rennes2.fr/fullchain.pem`
* Certificat intermédiaire : `/applis/certificate-tools/live/toto.univ-rennes2.fr/chain.pem`

## Check Nagios

Vous pouvez également monitorer vos certificats via Nagios (ou compatible) via NRPE.

Installez un check NRPE. Exemple sous Debian en rajoutant dans `/etc/nagios/nrpe.d/check_certs.cfg` :

```text
command[check_certs]=/applis/certificate-tools/certs.sh -c 90:30
```

## Droits d'accès aux certificats

Si vous utilisez une application qui ne lit pas les certificats "en tant que root", pour ensuite changer d'utilisateur, rajoutez l'utilisateur au groupe `ssl-cert` (Debian). Sinon lancez l'outil avec l'utilisateur qui a l'usage du certificat.

Vous pouvez personnaliser le user/group qui sera utilisé en définissant les variables CERT_USER et CERT_GROUP dans `/etc/default/certificate-tools` (si root)

Par défaut :

```bash
CERT_USER='root'
CERT_GROUP='ssl-cert'
```

Si le groupe ssl-cert n'existe pas, le groupe root sera utilisé.

## Production d'un fichier PFX / PKCS#12

Vous pouvez configurer certificate-tools pour produire un fichier au format PKCS#12

Dans ce cas vous devez rajouter les variables suivantes au fichier `/etc/default/certificate-tools` :

CERT_PFX_PASSWORD="votre mot de passe pour le fichier PFX"

Le fichier PFX sera alors accessible par tout utilisateur du serveur (chmod 644)

## Résultat d'un tree

```bash
/applis/certificate-tools
├── archive
│   ├── toto-preprod.univ-rennes2.fr
│   │   ├── 2020-toto-preprod.univ-rennes2.fr-chain.pem
│   │   ├── 2020-toto-preprod.univ-rennes2.fr-fullchain.pem
│   │   ├── 2020-toto-preprod.univ-rennes2.fr.key
│   │   └── 2020-toto-preprod.univ-rennes2.fr.pem
│   └── toto.univ-rennes2.fr
│       ├── 2018-toto.univ-rennes2.fr-chain.pem
│       ├── 2018-toto.univ-rennes2.fr-fullchain.pem
│       ├── 2018-toto.univ-rennes2.fr.key
│       ├── 2018-toto.univ-rennes2.fr.pem
│       ├── 2020-toto.univ-rennes2.fr-chain.pem
│       ├── 2020-toto.univ-rennes2.fr-fullchain.pem
│       ├── 2020-toto.univ-rennes2.fr.key
│       └── 2020-toto.univ-rennes2.fr.pem
├── certs.sh
├── live
│   ├── toto.fr
│   │   ├── cert.pem -> ../../archive/toto.univ-rennes2.fr/2020-toto.univ-rennes2.fr.pem
│   │   ├── chain.pem -> ../../archive/toto.univ-rennes2.fr/2020-toto.univ-rennes2.fr-chain.pem
│   │   ├── fullchain.pem -> ../../archive/toto.univ-rennes2.fr/2020-toto.univ-rennes2.fr-fullchain.pem
│   │   └── privkey.pem -> ../../archive/toto.univ-rennes2.fr/2020-toto.univ-rennes2.fr.key
│   ├── toto-preprod.uhb.fr
│   │   ├── cert.pem -> ../../archive/toto-preprod.univ-rennes2.fr/2020-toto-preprod.univ-rennes2.fr.pem
│   │   ├── chain.pem -> ../../archive/toto-preprod.univ-rennes2.fr/2020-toto-preprod.univ-rennes2.fr-chain.pem
│   │   ├── fullchain.pem -> ../../archive/toto-preprod.univ-rennes2.fr/2020-toto-preprod.univ-rennes2.fr-fullchain.pem
│   │   └── privkey.pem -> ../../archive/toto-preprod.univ-rennes2.fr/2020-toto-preprod.univ-rennes2.fr.key
│   ├── toto-preprod.univ-rennes2.fr
│   │   ├── cert.pem -> ../../archive/toto-preprod.univ-rennes2.fr/2020-toto-preprod.univ-rennes2.fr.pem
│   │   ├── chain.pem -> ../../archive/toto-preprod.univ-rennes2.fr/2020-toto-preprod.univ-rennes2.fr-chain.pem
│   │   ├── fullchain.pem -> ../../archive/toto-preprod.univ-rennes2.fr/2020-toto-preprod.univ-rennes2.fr-fullchain.pem
│   │   └── privkey.pem -> ../../archive/toto-preprod.univ-rennes2.fr/2020-toto-preprod.univ-rennes2.fr.key
│   ├── toto.uhb.fr
│   │   ├── cert.pem -> ../../archive/toto.univ-rennes2.fr/2020-toto.univ-rennes2.fr.pem
│   │   ├── chain.pem -> ../../archive/toto.univ-rennes2.fr/2020-toto.univ-rennes2.fr-chain.pem
│   │   ├── fullchain.pem -> ../../archive/toto.univ-rennes2.fr/2020-toto.univ-rennes2.fr-fullchain.pem
│   │   └── privkey.pem -> ../../archive/toto.univ-rennes2.fr/2020-toto.univ-rennes2.fr.key
│   ├── toto.univ-rennes2.fr
│   │   ├── cert.pem -> ../../archive/toto.univ-rennes2.fr/2020-toto.univ-rennes2.fr.pem
│   │   ├── chain.pem -> ../../archive/toto.univ-rennes2.fr/2020-toto.univ-rennes2.fr-chain.pem
│   │   ├── fullchain.pem -> ../../archive/toto.univ-rennes2.fr/2020-toto.univ-rennes2.fr-fullchain.pem
│   │   └── privkey.pem -> ../../archive/toto.univ-rennes2.fr/2020-toto.univ-rennes2.fr.key
│   └── www.toto.fr
│       ├── cert.pem -> ../../archive/toto.univ-rennes2.fr/2020-toto.univ-rennes2.fr.pem
│       ├── chain.pem -> ../../archive/toto.univ-rennes2.fr/2020-toto.univ-rennes2.fr-chain.pem
│       ├── fullchain.pem -> ../../archive/toto.univ-rennes2.fr/2020-toto.univ-rennes2.fr-fullchain.pem
│       └── privkey.pem -> ../../archive/toto.univ-rennes2.fr/2020-toto.univ-rennes2.fr.key
└── README.md
```

## Contribute

See [CONTRIBUTING.md](CONTRIBUTING.md)

## License

This program is free software: you can redistribute it and/or modify
it under the terms of the [GNU General Public License v3.0 or later](LICENSE)
as published by the Free Software Foundation.

The program in this repository meet the requirements to be REUSE compliant,
meaning its license and copyright is expressed in such as way so that it
can be read by both humans and computers alike.

For more information, see https://reuse.software/
