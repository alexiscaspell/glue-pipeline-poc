#!/usr/bin/env bash
set -eo pipefail

################################# ---- VARIABLES ---- #################################
export AWS_ACCESS_KEY_ID="$AWS_ACCESS_KEY_ID"
export AWS_SECRET_ACCESS_KEY="$AWS_SECRET_ACCESS_KEY"
export AWS_DEFAULT_REGION="us-east-1"

CREDENTIALS=$(aws sts assume-role --role-arn $DEPLOYMENT_ROLE --role-session-name aws-role --duration-seconds 900)

export AWS_ACCESS_KEY_ID="$(echo ${CREDENTIALS} | jq -r '.Credentials.AccessKeyId')"
export AWS_SECRET_ACCESS_KEY="$(echo ${CREDENTIALS} | jq -r '.Credentials.SecretAccessKey')"
export AWS_SESSION_TOKEN="$(echo ${CREDENTIALS} | jq -r '.Credentials.SessionToken')"
export AWS_EXPIRATION=$(echo ${CREDENTIALS} | jq -r '.Credentials.Expiration')

PARAMETERS_ENVIRONMENT="dev"

BUCKET="tostado-$PARAMETERS_ENVIRONMENT-glue-bucket"
GLUE_ROLE="$GLUE_ROLE"
SOURCE_VERSION=${SOURCE_VERSION:-$(git rev-parse HEAD)}

JOBS_FOLDER="jobs"

################################# ---- EJECUCION ---- #################################

# Lista todos los jobs que ya existen
aws glue get-jobs | jq -r '.Jobs[].Name' > listjobs.txt

mkdir $JOBS_FOLDER/normalized

#Se copian todos los archivos python que tuvieron cambios a la carpeta de scripts del bucket
for i in $(git diff-tree --no-commit-id --name-only -r $SOURCE_VERSION -- *.py); do 
    aws s3 cp $i s3://$BUCKET/scripts/ 
done

#Se copian todos los archivos jar que tuvieron cambios a la carpeta de library del bucket
for i in $(git diff-tree --no-commit-id --name-only -r $SOURCE_VERSION -- *.jar); do 
    aws s3 cp $i s3://$BUCKET/library/ 
done

# Modifica con jq varios parametros de cada job y los guarda en una carpeta normalized
for i in $(find $JOBS_FOLDER/ -maxdepth 1 -type f -name "*.json" -printf '%f\n' | sed 's#.json##'); do
    jq '.Role = "'$GLUE_ROLE'"' $JOBS_FOLDER/$i.json | \
    jq 'del( .Connections )' | \
    jq '.Command.ScriptLocation = "s3://'$BUCKET'/scripts/'$i'.py"' | \
    jq '.DefaultArguments."--TempDir" = "s3://'$BUCKET'/temporary/"' | \
    jq '.DefaultArguments."--spark-event-logs-path" = "s3://'$BUCKET'/sparkHistoryLogs/"' | \
    jq '.DefaultArguments."--env" = "'$PARAMETERS_ENVIRONMENT'"'  > ${JOBS_FOLDER}/normalized/$i${VARIABLES_YAML_CONFIG}.json
done

# Copia la carpeta normalized al bucket de jobs
aws s3 cp $JOBS_FOLDER/normalized/ s3://$BUCKET/jobs --recursive

# Copia los schdedules al bucket de schedules
aws s3 cp schedules/  s3://$BUCKET/schedules --recursive

echo "Upserting jobs ..."

# Lista todos los jobs que estaban en normalized y si estaban creados les quita los tags y actualiza o crea el job
for i in $(find $JOBS_FOLDER/normalized/ -maxdepth 1 -type f -name "*.json" -printf '%f\n' | sed 's#.json##' ); do 
    grep -Fxq $i listjobs.txt && jq 'del(.Tags)' $JOBS_FOLDER/normalized/$i.json >> $i.json \
    && echo "Updating job $i ..." && aws glue update-job --job-name $i --job-update  file://$i.json \
    || echo "Creating job $i ..." && aws glue create-job --name $i --cli-input-json file://$JOBS_FOLDER/normalized/$i.json
done