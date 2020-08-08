#!/bin/bash
set -e

#
# TAKEN FROM HERE: #https://github.com/labs42io/circleci-monorepo
#
# The root directory of packages.
# Use `.` if your packages are located in root.
ROOT="." 
REPOSITORY_TYPE="github"
CIRCLE_API="https://circleci.com/api"

############################################
## 0. Environments
############################################

echo "################################################################"
echo "################################################################"
echo "## CIRCLE TRIGGER SCRIPT ENV"
echo "################################################################"
echo " - CIRCLE_PULL_REQUEST:     ${CIRCLE_PULL_REQUEST}"
echo " - CIRCLE_PULL_REQUESTS:    ${CIRCLE_PULL_REQUESTS}"
echo " - CIRCLE_PROJECT_REPONAME: ${CIRCLE_PROJECT_REPONAME}"
echo " - CIRCLE_PR_REPONAME:      ${CIRCLE_PR_REPONAME}"
echo " - CIRCLE_PR_NUMBER:        ${CIRCLE_PR_NUMBER}"
echo " - CIRCLE_BRANCH:           ${CIRCLE_BRANCH}"

echo "################################################################"

############################################
## 1. Commit SHA of last CI build
############################################

echo "################################################################"
echo "################################################################"
echo "## CIRCLE TRIGGER SCRIPT "
echo "################################################################"
echo "################################################################"

LAST_COMPLETED_BUILD_URL="${CIRCLE_API}/v1.1/project/${REPOSITORY_TYPE}/${CIRCLE_PROJECT_USERNAME}/${CIRCLE_PROJECT_REPONAME}/tree/${CIRCLE_BRANCH}?filter=completed&limit=100&shallow=true"
echo "LAST_COMPLETED_BUILD_URL: $LAST_COMPLETED_BUILD_URL"
curl -Ss -u ${CIRCLE_TOKEN}: ${LAST_COMPLETED_BUILD_URL} > circle.json
LAST_COMPLETED_BUILD_SHA=`cat circle.json | jq -r 'map(select(.status == "success") | select(.workflows.workflow_name != "ci")) | .[0]["vcs_revision"]'`

echo "#### LAST_COMPLETED_BUILD_SHA: "
echo "${LAST_COMPLETED_BUILD_SHA}"

if  [[ ${LAST_COMPLETED_BUILD_SHA} == "null" ]] || [[ $(git cat-file -t $LAST_COMPLETED_BUILD_SHA) != "commit" ]]; then
  echo -e "\e[93mThere are no completed CI builds in branch ${CIRCLE_BRANCH}.\e[0m"

  # Adapted from https://gist.github.com/joechrysler/6073741
  TREE=$(git show-branch -a 2>/dev/null \
    | grep '\*' \
    | grep -v `git rev-parse --abbrev-ref HEAD` \
    | sed 's/.*\[\(.*\)\].*/\1/' \
    | sed 's/[\^~].*//' \
    | uniq)

  REMOTE_BRANCHES=$(git branch -r | sed 's/\s*origin\///' | tr '\n' ' ')
  PARENT_BRANCH=master

  echo "#### TREE: "
  echo "${TREE}"

  echo "#### REMOTE_BRANCHES: "
  echo "${REMOTE_BRANCHES}"
  
  for BRANCH in ${TREE[@]}
  do
    BRANCH=${BRANCH#"origin/"}
    if [[ " ${REMOTE_BRANCHES[@]} " == *" ${BRANCH} "* ]]; then
        echo "Found the parent branch: ${CIRCLE_BRANCH}..${BRANCH}"
        PARENT_BRANCH=$BRANCH
        break
    fi
  done

  echo "Searching for CI builds in branch '${PARENT_BRANCH}' ..."

  LAST_COMPLETED_BUILD_URL="${CIRCLE_API}/v1.1/project/${REPOSITORY_TYPE}/${CIRCLE_PROJECT_USERNAME}/${CIRCLE_PROJECT_REPONAME}/tree/${PARENT_BRANCH}?filter=completed&limit=100&shallow=true"
  LAST_COMPLETED_BUILD_SHA=`curl -Ss -u "${CIRCLE_TOKEN}:" "${LAST_COMPLETED_BUILD_URL}" \
    | jq -r "map(\
      select(.status == \"success\") | select(.workflows.workflow_name != \"ci\") | select(.build_num < ${CIRCLE_BUILD_NUM})) \
    | .[0][\"vcs_revision\"]"`
fi

if [[ ${LAST_COMPLETED_BUILD_SHA} == "null" ]] || [[ $(git cat-file -t $LAST_COMPLETED_BUILD_SHA) != "commit" ]]; then
  echo -e "\e[93mNo CI builds for branch ${PARENT_BRANCH}. Using master.\e[0m"
  LAST_COMPLETED_BUILD_SHA=$(git rev-parse origin/master)
fi
echo "PARENT_BRANCH: ${PARENT_BRANCH}"
############################################
## 2. Changed packages
############################################

#MODIFIED: we use a txt config to determine which directory paths represent packages with their own CircleCI workflow.
#PACKAGES=$(ls ${ROOT} -l | grep ^d | awk '{print $9}')
PACKAGES=$(<.circleci/packages.txt)
echo "Packages: "
echo "$PACKAGES"

echo
echo "Searching for changes since commit [${LAST_COMPLETED_BUILD_SHA:0:7}] ..."

## The CircleCI API parameters object
PARAMETERS='"trigger":false'
COUNT=0

# Get the list of workflows in current branch for which the CI is currently in failed state
FAILED_WORKFLOWS=$(cat circle.json \
  | jq -r "map(select(.branch == \"${CIRCLE_BRANCH}\")) \
  | group_by(.workflows.workflow_name) \
  | .[] \
  | {workflow: .[0].workflows.workflow_name, status: .[0].status} \
  | select(.status == \"failed\") \
  | .workflow")

echo "Workflows currently in failed status: (${FAILED_WORKFLOWS[@]})."

for PACKAGE in ${PACKAGES[@]}
do
  PACKAGE_PATH=${ROOT#.}/$PACKAGE
  if [ -n "${CIRCLE_PULL_REQUEST}" ]; then
    export TERM=xterm
    LATEST_COMMIT_SINCE_LAST_BUILD=$(git log master.. --name-only --oneline -- ${PACKAGE} | sed '/ /d' | sed '/\//!d' | sed 's/\/.*//' | sort | uniq)
    echo "PULL-REQUEST HANDLINE (${PACKAGE} - ${LATEST_COMMIT_SINCE_LAST_BUILD})"
    git log
    
  else
    LATEST_COMMIT_SINCE_LAST_BUILD=$(git log -1 $LAST_COMPLETED_BUILD_SHA..$CIRCLE_SHA1 --format=format:%H --full-diff -- ${PACKAGE_PATH#/})
    echo "DEFAULT (MASTER / BRANCH) HANDLINE (${LATEST_COMMIT_SINCE_LAST_BUILD})"
    
  fi
  

  if [[ -z "$LATEST_COMMIT_SINCE_LAST_BUILD" ]]; then
    INCLUDED=0
    for FAILED_BUILD in ${FAILED_WORKFLOWS[@]}
    do
      if [[ "$PACKAGE" == "$FAILED_BUILD" ]]; then
        INCLUDED=1
        PARAMETERS+=", \"$PACKAGE\":true"
        COUNT=$((COUNT + 1))
        echo -e "\e[36m  [+] ${PACKAGE} \e[21m (included because failed since last build)\e[0m"
        break
      fi
    done

    if [[ "$INCLUDED" == "0" ]]; then
      echo -e "\e[90m  [-] $PACKAGE \e[0m"
    fi
  else
    PARAMETERS+=", \"$PACKAGE\":true"
    COUNT=$((COUNT + 1))
    echo -e "\e[36m  [+] ${PACKAGE} \e[21m (changed in [${LATEST_COMMIT_SINCE_LAST_BUILD:0:7}])\e[0m"
  fi
done

if [[ $COUNT -eq 0 ]]; then
  echo -e "\e[93mNo changes detected in packages. Skip triggering workflows.\e[0m"
  exit 0
fi

echo "Changes detected in ${COUNT} package(s)."

############################################
## 3. CicleCI REST API call
############################################
PARAMETERS=${PARAMETERS//\//_}
DATA="{ \"branch\": \"$CIRCLE_BRANCH\", \"parameters\": { $PARAMETERS } }"
echo "Triggering pipeline with data:"
echo -e "  $DATA"

URL="${CIRCLE_API}/v2/project/${REPOSITORY_TYPE}/${CIRCLE_PROJECT_USERNAME}/${CIRCLE_PROJECT_REPONAME}/pipeline"

HTTP_RESPONSE=$(curl -s -u ${CIRCLE_TOKEN}: -o response.txt -w "%{http_code}" -X POST --header "Content-Type: application/json" -d "$DATA" "$URL")

if [ "$HTTP_RESPONSE" -ge "200" ] && [ "$HTTP_RESPONSE" -lt "300" ]; then
    echo "API call succeeded."
    echo "Response:"
    cat response.txt
else
    echo -e "\e[93mReceived status code: ${HTTP_RESPONSE}\e[0m"
    echo "Response:"
    cat response.txt
    exit 1
fi