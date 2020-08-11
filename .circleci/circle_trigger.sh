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
echo "## CIRCLE TRIGGER SCRIPT ENV"
echo "################################################################"
echo " - CIRCLE_PULL_REQUEST:     ${CIRCLE_PULL_REQUEST}"
echo " - CIRCLE_PULL_REQUESTS:    ${CIRCLE_PULL_REQUESTS}"
echo " - CIRCLE_PROJECT_REPONAME: ${CIRCLE_PROJECT_REPONAME}"
echo " - CIRCLE_PR_REPONAME:      ${CIRCLE_PR_REPONAME}"
echo " - CIRCLE_PR_NUMBER:        ${CIRCLE_PR_NUMBER}"
echo " - CIRCLE_BRANCH:           ${CIRCLE_BRANCH}"
echo " - CIRCLE_BUILD_NUM:        ${CIRCLE_BUILD_NUM}"
echo " - CIRCLE_BUILD_URL:        ${CIRCLE_BUILD_URL}"
echo " - CIRCLE_WORKFLOW_ID:      ${CIRCLE_WORKFLOW_ID}"
echo " - CIRCLE_SHA1:             ${CIRCLE_SHA1}"
echo " - PATHS:                   ${PATHS}"
echo " - 1:                       $1"

echo "################################################################"
echo "## 1. Commit SHA of last successful CI build "
echo "################################################################"

LAST_COMPLETED_BUILD_URL="${CIRCLE_API}/v1.1/project/${REPOSITORY_TYPE}/${CIRCLE_PROJECT_USERNAME}/${CIRCLE_PROJECT_REPONAME}/tree/${CIRCLE_BRANCH}?filter=completed&limit=100&shallow=true"
curl -Ss -u ${CIRCLE_TOKEN}: ${LAST_COMPLETED_BUILD_URL} > circle.json
LAST_COMPLETED_BUILD_SHA=`cat circle.json | jq -r 'map(select(.status == "success") | select(.workflows.workflow_name != "ci")) | .[0]["vcs_revision"]'`
PARENT_BRANCH=$(git log --pretty=format:'%D' HEAD^ | grep 'origin/' | head -n1 | sed 's@origin/@@' | sed 's@,.*@@')

echo " - LAST_COMPLETED_BUILD_SHA: '${LAST_COMPLETED_BUILD_SHA}'"
echo " - PARENT_BRANCH:            '${PARENT_BRANCH}'"

echo "################################################################"
echo "## 2. Determine Package Changes"
echo "################################################################"

# Parsing configuration file with following format:
# <package_name1>=<path_segment1>,<path_segment2> 
# <package_name2>=<path_segment3>,<path_segment4>
#
PACKAGES=$(<.circleci/packages.txt)

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

if [ -n "${CIRCLE_PULL_REQUEST}" ]; then
  echo "PULL-REQUEST CHANGE DETECTION: Taking all commits in this PR into account to trigger workflows for all changed packages!"
else
  echo "DEFAULT (MASTER/BRANCH) CHANGE DETECTION: Only taking changes of the last commits into account. Only workflows of packages which have been changed in this commit are triggered!"
fi

for PACKAGE in ${PACKAGES[@]}
do

  echo " - Current Package: ${PACKAGE}"
  IFS='='
  read -ra ADDR <<< "${PACKAGE}"
  echo " - Package:               ${ADDR[0]}"
  echo " - Package Path Segments: ${ADDR[1]}"
  
  IFS=','
  read -ra PATHSEGMENTS <<< "${ADDR[1]}"
  
  for PATHSEGMENT in ${PATHSEGMENTS[@]}; do
    echo "--> ${PATHSEGMENT}"
    PACKAGE_PATH=${ROOT#.}/${PATHSEGMENT}

    if [ -n "${CIRCLE_PULL_REQUEST}" ]; then
      LATEST_COMMIT_SINCE_LAST_BUILD=$(git --no-pager log origin/${PARENT_BRANCH}..${CIRCLE_BRANCH} --name-only --oneline -- ${PACKAGE} | sed '/ /d' | sed '/\//!d' | sed 's/\/.*//' | sort | uniq)
      echo "git --no-pager log origin/${PARENT_BRANCH}..${CIRCLE_BRANCH} --name-only --oneline -- ${PACKAGE} | sed '/ /d' | sed '/\//!d' | sed 's/\/.*//' | sort | uniq)"
      if [ -n "${LATEST_COMMIT_SINCE_LAST_BUILD}" ]; then
        LATEST_COMMIT_SINCE_LAST_BUILD="## PR ##"
      fi
    else
      LATEST_COMMIT_SINCE_LAST_BUILD=$(git log -1 $LAST_COMPLETED_BUILD_SHA..$CIRCLE_SHA1 --format=format:%H --full-diff -- ${PACKAGE_PATH#/})
    fi

    if [[ -z "$LATEST_COMMIT_SINCE_LAST_BUILD" ]]; then
      INCLUDED=0
      for FAILED_BUILD in ${FAILED_WORKFLOWS[@]}; do
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

done
  
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