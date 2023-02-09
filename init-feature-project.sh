#!/bin/bash

function get_attr_and_val {
    AV=`grep $1 $2 | tr -d ' '` 
    echo $AV 
}

function get_fattr {
    ATTR=`echo $1 | sed -e 's/^[[:space:]]*//' | cut -f1 -d:`
    echo $ATTR
}

function get_fval {
    VAL=`echo $1 | sed -e 's/^[[:space:]]*//' | cut -f2 -d:`
    echo $VAL
}

# Constants
FEATURE_TEMPLATES_DIR="templates"
UI_SCHEMA_JSON_FILE="ui.schema.json"
SCHEMA_PARSER_RULES_FILE="schemaParserRules.json"
UI_SCHEMA_JSON_TEMPLATE="${UI_SCHEMA_JSON_FILE}.template"
SCHEMA_PARSER_RULES_TEMPLATE="${SCHEMA_PARSER_RULES_FILE}.template"
MANIFEST_YAML="manifest.yaml"
MANIFEST_YAML_TEMPLATE=""

# Local variables
FEATURE_TEMPLATE_FILE=""
FEATURE_DIRECTORY=""
USAGE="Usage: $(basename $0) [-f file] [-d directory]"

while getopts 'f:d:h' opt; do
    case "$opt" in
        f)
          FEATURE_TEMPLATE_FILE="$OPTARG"
          ;;
        d)
          FEATURE_DIRECTORY="$OPTARG"
          ;;
        h)
          #Usage: $(basename $0) [-f file] [-d directory]
          echo $USAGE 
          exit 0
          ;;
        :)
          echo -e "Option requires an argument.\n${USAGE}"
          exit 1
          ;;
        ?)
          echo -e "Invalid command option.\n${USAGE}"
          exit 1
          ;;
    esac
done
shift "$(($OPTIND -1))"

echo "FEATURE_TEMPLATE_FILE: ${FEATURE_TEMPLATE_FILE}"
echo "FEATURE_DIRECTORY: ${FEATURE_DIRECTORY}"

if [ ! -f $FEATURE_TEMPLATE_FILE ] ; then
    echo "File ${FEATURE_TEMPLATE_FILE} does not exists"
    exit 1
fi

if [ ! -d $FEATURE_DIRECTORY ] ; then
    echo "Directory ${FEATURE_DIRECTORY} does not exists"
    exit 1
fi

# Make base feature and version directory
FEATURE_ID_AV=`get_attr_and_val feature_id $FEATURE_TEMPLATE_FILE`
FEATURE_VERSION_AV=`get_attr_and_val feature_version $FEATURE_TEMPLATE_FILE`
FEATURE_ID=`get_fval ${FEATURE_ID_AV}`
FEATURE_VERSION=`get_fval ${FEATURE_VERSION_AV}`
if [ -z $FEATURE_ID ] ; then
    echo "feature_id is a required field in template file"
    exit 1
fi

if [ -z $FEATURE_VERSION ] ; then
    echo "feature_version is a required field in template file"
    exit 1
fi

# Set the base feature directory to the feature directory/featureid/featureversion
BASE_FEATURE_DIR="${FEATURE_DIRECTORY}/${FEATURE_ID}/${FEATURE_VERSION}"
mkdir -p $BASE_FEATURE_DIR

# Get the feature install type and create the insall type directory, routing and schemas
# directory under that
# TODO add validation of install type value
FEATURE_INST_TYPE_AV=`get_attr_and_val feature_install_type $FEATURE_TEMPLATE_FILE`
FEATURE_INST_TYPE=`get_fval ${FEATURE_INST_TYPE_AV}`
SCHEMA_DIR="${BASE_FEATURE_DIR}/${FEATURE_INST_TYPE}/schemas"
ROUTING_DIR="${BASE_FEATURE_DIR}/${FEATURE_INST_TYPE}/routing"
mkdir -p ${SCHEMA_DIR}
mkdir -p ${ROUTING_DIR}

# Copy over ui.schema.json from templates directory
cp "${FEATURE_TEMPLATES_DIR}/${UI_SCHEMA_JSON_TEMPLATE}" $SCHEMA_DIR

# Replace feature_id placeholder
sed "s/feature_id/$FEATURE_ID/g" "${SCHEMA_DIR}/${UI_SCHEMA_JSON_TEMPLATE}" > "${SCHEMA_DIR}/${UI_SCHEMA_JSON_FILE}" 
rm "${SCHEMA_DIR}/${UI_SCHEMA_JSON_TEMPLATE}"

# Copy over the schemaParserRules.json.template to feature directory
cp "${FEATURE_TEMPLATES_DIR}/${SCHEMA_PARSER_RULES_TEMPLATE}" "${SCHEMA_DIR}/${SCHEMA_PARSER_RULES_FILE}"

# Is this a replicaSet install type? If so, create the helm directory
if [ $FEATURE_INST_TYPE == "replicaSet" ] ; then
    MANIFEST_YAML_TEMPLATE="${MANIFEST_YAML}.${FEATURE_INST_TYPE}.template"
    mkdir "${BASE_FEATURE_DIR}/${FEATURE_INST_TYPE}/helm"
    touch "${BASE_FEATURE_DIR}/${FEATURE_INST_TYPE}/helm/values.yaml"
fi 

cp "${FEATURE_TEMPLATES_DIR}/${MANIFEST_YAML_TEMPLATE}" $BASE_FEATURE_DIR
MANIFEST_TEMPLATE_FILE="${BASE_FEATURE_DIR}/${MANIFEST_YAML_TEMPLATE}"
TEMP_MANIFEST_TEMPLATE_FILE="${BASE_FEATURE_DIR}/${MANIFEST_YAML_TEMPLATE}.tmp"
cat $FEATURE_TEMPLATE_FILE | while read f ; do
    ATTR=`echo $f | cut -f1 -d:`
    if [[ $ATTR == *"url"* ]] ; then
        VAL=`echo $f | sed -e 's/^[[:space:]]*//' | cut -f2,3 -d:`
        ESCAPED_VAL=$(printf '%s\n' "$VAL" | sed -e 's/[\/&]/\\&/g')
        sed "s/$ATTR/$ESCAPED_VAL/g" $MANIFEST_TEMPLATE_FILE > $TEMP_MANIFEST_TEMPLATE_FILE
    else
        VAL=`echo $f | cut -f2 -d: | xargs`
        sed "s/$ATTR/$VAL/g" $MANIFEST_TEMPLATE_FILE > $TEMP_MANIFEST_TEMPLATE_FILE
    fi
    mv $TEMP_MANIFEST_TEMPLATE_FILE $MANIFEST_TEMPLATE_FILE
done
mv $MANIFEST_TEMPLATE_FILE "${BASE_FEATURE_DIR}/${MANIFEST_YAML}"
MANIFEST_FILE="${BASE_FEATURE_DIR}/${MANIFEST_YAML}"

# Handle the Ingress portion.
CLUSTER_INGRESS_TEMPLATE_FILE="${FEATURE_TEMPLATES_DIR}/cluster.ingress.json.template"
EXTERNAL_INGRESS_TEMPLATE_FILE="${FEATURE_TEMPLATES_DIR}/external.ingress.json.template"
FEATURE_EGRESS_TEMPLATE_FILE="${FEATURE_TEMPLATES_DIR}/feature.egress.json.template"
INTERNAL_INGRESS_AV=`get_attr_and_val feature_internal_ingress $FEATURE_TEMPLATE_FILE`
INTERNAL_INGRESS=`get_fval ${INTERNAL_INGRESS_AV}`
EXTERNAL_INGRESS_AV=`get_attr_and_val feature_external_ingress $FEATURE_TEMPLATE_FILE`
EXTERNAL_INGRESS=`get_fval ${EXTERNAL_INGRESS_AV}`
CONNECTIONS_AV=`get_attr_and_val feature_connections $FEATURE_TEMPLATE_FILE`
CONNECTIONS=`get_fval ${CONNECTIONS_AV}`

# If an internal or external ingress has been supplied, add an ingresses section to the manifest file
if [[ $INTERNAL_INGRESS == 'yes' || $EXTERNAL_INGRESS == 'yes' ]]; then
  echo '    ingresses:' >> ${MANIFEST_FILE}
fi

# If an internal ingress has been supplied, update the manifest with the appropriate config
# and create the internal ingress routing file, which will take the form of cluster-feature_id-ingress.json.
# This file is created under the routing directory.
if [ $INTERNAL_INGRESS == 'yes' ]; then
  INTERNAL_INGRESS_ID="cluster-${FEATURE_ID}-ingress"
  INTERNAL_INGRESS_ROUTING_FILE="${INTERNAL_INGRESS_ID}.json"
  cp "${CLUSTER_INGRESS_TEMPLATE_FILE}" "${ROUTING_DIR}/${INTERNAL_INGRESS_ROUTING_FILE}"
  echo "      - id: ${INTERNAL_INGRESS_ID}" >> ${MANIFEST_FILE}
  echo "        name: Cluster connection" >> ${MANIFEST_FILE}
  echo "        isExternal: False" >> ${MANIFEST_FILE}
  echo "        default: True" >> ${MANIFEST_FILE}
fi

# If an external ingress has been supplied, update the manifest with the appropriate config
# and create the external ingress routing file, which will take the form of external-feature_id-ingress.json.
# This file is created under the routing directory.
if [ $EXTERNAL_INGRESS == 'yes' ]; then
  EXTERNAL_INGRESS_ID="external-${FEATURE_ID}-ingress"
  EXTERNAL_INGRESS_ROUTING_FILE="${EXTERNAL_INGRESS_ID}.json"
  cp "${EXTERNAL_INGRESS_TEMPLATE_FILE}" "${ROUTING_DIR}/${EXTERNAL_INGRESS_ROUTING_FILE}"
  echo "      - id: ${EXTERNAL_INGRESS_ID}" >> ${MANIFEST_FILE}
  echo "        name: External connection" >> ${MANIFEST_FILE}
  echo "        isExternal: True" >> ${MANIFEST_FILE}
  echo "        default: True" >> ${MANIFEST_FILE}
fi

# If a connections has been supplied, update the manifest with the appropriate config
# and create the feature egress routing file, which will take the form of egress-feature_id.json.
# This file is created under the routing directory.
if [ $CONNECTIONS == 'yes' ]; then
  FEATURE_EGRESS_ID="egress-${FEATURE_ID}"
  FEATURE_EGRESS_ROUTING_FILE="${FEATURE_EGRESS_ID}.json"
  cp "${FEATURE_EGRESS_TEMPLATE_FILE}" "${ROUTING_DIR}/${FEATURE_EGRESS_ROUTING_FILE}"
  echo '    connections:' >> ${MANIFEST_FILE}
  echo "      - id: ${FEATURE_EGRESS_ID}" >> ${MANIFEST_FILE}
  echo "        description: TODO - Add connection description here" >> ${MANIFEST_FILE}
  echo "        featureReference: TODO - Add feature reference here" >> ${MANIFEST_FILE}
fi