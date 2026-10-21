# Agent Sentry

À chaque passage, pour chaque projet `actif` de `config.json` :

1. récupère les issues Sentry `unresolved` de l'environnement configuré, apparues dans
   la `fenetre` et au-dessus du seuil (`seuil_evenements` **ou** `seuil_utilisateurs`) ;
2. saute celles déjà traitées (`etat/<projet>.traites`) ou qui ont déjà une MR
   `sentry/<shortId>` (ouverte, fusionnée ou fermée) ;
3. crée un worktree depuis `origin/<branche_cible>` et lance `claude -p` avec
   `prompt.md`, l'issue et la stacktrace du dernier événement ;
4. si Claude a corrigé : commit, push, **MR en Draft** (label `sentry-auto`), lien
   ajouté en commentaire sur l'issue Sentry. Sinon : diagnostic en commentaire Sentry.

Au plus `max_mr_par_passage` MR par passage. L'agent ne fusionne jamais.

## Sécurité
- Claude n'a que lecture/écriture de fichiers et `git diff/status/log/show/blame` :
  pas de réseau, pas de push, pas de jeton. C'est le script qui pousse et ouvre la MR.
- Les données Sentry viennent de la prod (texte saisi par des utilisateurs) : le
  prompt les traite comme données, et la MR en Draft impose une relecture humaine.

## Installation
1. Jetons dans `~/.config/agent-sentry/env` (`chmod 600`) :
   ```
   SENTRY_TOKEN=...   # scopes : project:read, event:read, event:write (commentaires)
   GITLAB_TOKEN=...   # scope : api
   ```
2. `cp config.example.json config.json`, puis renseigner les URL Sentry/GitLab et, par projet, `gitlab` et `depot` (clone local), passer `actif` à `true`.
3. Essai à blanc (aucun push, diff gardé dans `logs/<shortId>/`) :
   `DRY_RUN=1 ./run.sh`
4. Planifier (ex. toutes les heures en semaine, 8 h–19 h) :
   `crontab -e` → `0 8-19 * * 1-5 /chemin/vers/agent-sentry/run.sh >/dev/null 2>&1`

Journal : `logs/agent.log` ; détail par issue : `logs/<shortId>/` (prompt, sortie Claude, mr.md ou diagnostic.md, diff).
