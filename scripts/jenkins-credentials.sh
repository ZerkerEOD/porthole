#!/usr/bin/env bash
# Creates (or replaces) the porthole-* Jenkins credentials and the porthole-mobile job from
# the personal sops store, over the Jenkins REST API. Run from the repository root.
#   scripts/jenkins-credentials.sh creds        credentials only
#   scripts/jenkins-credentials.sh job          the pipeline job only
#   scripts/jenkins-credentials.sh all
# Needs in sops: JENKINS_URL (not secret), JENKINS_USER (not secret), JENKINS_API_TOKEN, plus
# the PORTHOLE_* entries listed below. Secret values never touch argv or the terminal.
set -euo pipefail
cd "$(dirname "$0")/.."
SOPS_DIR="$HOME/.config/sops"
get() { (cd "$SOPS_DIR" && sops -d --extract "[\"$1\"][\"value\"]" zerkersec.yaml); }
has() { (cd "$SOPS_DIR" && grep -q "^$1:" zerkersec.yaml); }
JENKINS_URL="${JENKINS_URL:-$(get JENKINS_URL)}"
JENKINS_URL="${JENKINS_URL%/}"   # tolerate a trailing slash in sops
JENKINS_USER="${JENKINS_USER:-$(get JENKINS_USER)}"
NETRC="$(mktemp)"; trap 'rm -f "$NETRC"' EXIT; chmod 600 "$NETRC"
printf 'machine %s login %s password %s\n' "$(echo "$JENKINS_URL" | sed -E 's#https?://##; s#/.*##')" "$JENKINS_USER" "$(get JENKINS_API_TOKEN)" > "$NETRC"
CURL=(curl -g -sS --netrc-file "$NETRC" -o /dev/null -w '%{http_code}')
STORE="$JENKINS_URL/credentials/store/system/domain/_"
REPO_URL="${PORTHOLE_REPO_URL:-https://github.com/ZerkerEOD/porthole.git}"

drop() { "${CURL[@]}" -X POST "$STORE/credential/$1/doDelete" >/dev/null || true; }
put_string() { # id sops-name description
  has "$2" || { echo "skip $1: $2 not in sops" >&2; return; }
  drop "$1"
  local json; json="$(jq -n --arg id "$1" --arg d "$3" --arg v "$(get "$2")" \
    '{"":"0",credentials:{scope:"GLOBAL",id:$id,description:$d,secret:$v,"$class":"org.jenkinsci.plugins.plaincredentials.impl.StringCredentialsImpl"}}')"
  echo "$1 -> $("${CURL[@]}" -X POST "$STORE/createCredentials" --data-urlencode "json=$json")"
}
put_file() { # id sops-name filename description [base64]
  has "$2" || { echo "skip $1: $2 not in sops" >&2; return; }
  drop "$1"
  local tmp; tmp="$(mktemp)"; chmod 600 "$tmp"
  if [ "${5:-}" = "base64" ]; then get "$2" | base64 -d > "$tmp"; else get "$2" > "$tmp"; fi
  local json; json="$(jq -n --arg id "$1" --arg d "$4" --arg f "$3" \
    '{"":"0",credentials:{scope:"GLOBAL",id:$id,description:$d,file:"file0",fileName:$f,"$class":"org.jenkinsci.plugins.plaincredentials.impl.FileCredentialsImpl"}}')"
  echo "$1 -> $("${CURL[@]}" -X POST "$STORE/createCredentials" -F "file0=@$tmp;filename=$3" -F "json=$json")"
  rm -f "$tmp"
}

creds() {
  put_string porthole-match-password PORTHOLE_MATCH_PASSWORD 'Porthole: fastlane match passphrase'
  put_file   porthole-asc-api-key-p8 PORTHOLE_ASC_API_KEY_P8 AuthKey.p8 'Porthole: App Store Connect API key'
  put_string porthole-asc-key-id PORTHOLE_ASC_KEY_ID 'Porthole: ASC key id'
  put_string porthole-asc-issuer-id PORTHOLE_ASC_ISSUER_ID 'Porthole: ASC issuer id'
  put_string porthole-apple-team-id PORTHOLE_APPLE_TEAM_ID 'Porthole: Apple Team ID'
  put_file   porthole-android-upload-keystore PORTHOLE_UPLOAD_KEYSTORE_B64 upload.jks 'Porthole: Android upload keystore' base64
  put_string porthole-android-keystore-password PORTHOLE_UPLOAD_KEYSTORE_PASSWORD 'Porthole: upload keystore password'
  put_file   porthole-play-service-account-json PORTHOLE_PLAY_SERVICE_ACCOUNT_JSON play.json 'Porthole: Play upload service account'
  put_file   porthole-store-defines-json PORTHOLE_STORE_DEFINES_JSON store.json 'Porthole: Firebase client ids for --dart-define-from-file (not in git)'
}

job() {
  local xml; xml="$(cat <<XML
<?xml version='1.1' encoding='UTF-8'?>
<flow-definition plugin="workflow-job">
  <description>Porthole mobile builds (personal lane). iOS on the macos agent, Android on linux.</description>
  <keepDependencies>false</keepDependencies>
  <properties/>
  <definition class="org.jenkinsci.plugins.workflow.cps.CpsScmFlowDefinition" plugin="workflow-cps">
    <scm class="hudson.plugins.git.GitSCM" plugin="git">
      <configVersion>2</configVersion>
      <userRemoteConfigs><hudson.plugins.git.UserRemoteConfig><url>$REPO_URL</url></hudson.plugins.git.UserRemoteConfig></userRemoteConfigs>
      <branches><hudson.plugins.git.BranchSpec><name>*/main</name></hudson.plugins.git.BranchSpec></branches>
      <doGenerateSubmoduleConfigurations>false</doGenerateSubmoduleConfigurations>
      <submoduleCfg class="empty-list"/>
      <extensions/>
    </scm>
    <scriptPath>Jenkinsfile.mobile</scriptPath>
    <lightweight>true</lightweight>
  </definition>
  <triggers/>
  <disabled>false</disabled>
</flow-definition>
XML
)"
  local code; code="$("${CURL[@]}" -X POST "$JENKINS_URL/createItem?name=porthole-mobile" -H 'Content-Type: application/xml' --data-binary "$xml")"
  if [ "$code" = "400" ]; then
    code="$("${CURL[@]}" -X POST "$JENKINS_URL/job/porthole-mobile/config.xml" -H 'Content-Type: application/xml' --data-binary "$xml")"
    echo "job porthole-mobile updated -> $code"
  else
    echo "job porthole-mobile created -> $code"
  fi
}

case "${1:-all}" in
  creds) creds ;;
  job) job ;;
  all) creds; job ;;
  *) echo "usage: $0 creds|job|all" >&2; exit 2 ;;
esac
