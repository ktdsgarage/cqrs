#!/bin/bash

RESOURCE_GROUP="ictcoe-edu" #az group list -o table

# ===========================================
# CQRS Pattern 실습환경 구성 스크립트
# ===========================================

# 사용법 출력
print_usage() {
   cat << EOF
사용법:
   $0 <userid>

설명:
   CQRS 패턴 실습을 위한 Azure 리소스를 생성하고 애플리케이션을 배포합니다.
   리소스 이름이 중복되지 않도록 userid를 prefix로 사용합니다.

예제:
   $0 dg0100
EOF
}

# 유틸리티 함수
log() {
   local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
   echo "[$timestamp] $1" | tee -a $LOG_FILE
}

check_error() {
   if [ $? -ne 0 ]; then
       log "Error: $1"
       exit 1
   fi
}

# 사전 요구사항 체크
check_prerequisites() {
   log "사전 요구사항 체크 중..."

   # Java 체크
   if ! command -v java &> /dev/null; then
       log "Error: Java가 설치되어 있지 않습니다."
       exit 1
   fi

   # Docker 체크
   if ! command -v docker &> /dev/null; then
       log "Error: Docker가 설치되어 있지 않습니다."
       exit 1
   fi

   # Azure CLI 체크
   if ! command -v az &> /dev/null; then
       log "Error: Azure CLI가 설치되어 있지 않습니다."
       exit 1
   fi
}

# 환경 변수 설정
setup_environment() {
   log "환경 변수 설정 중..."

   USERID=$1
   NAME="${USERID}-cqrs"
   LOCATION="koreacentral"
   ACR_NAME="${USERID}cr"
   AKS_NAME="${USERID}-aks"

   # Namespace에 userid 추가
   DB_NAMESPACE="${USERID}-cqrs"
   APP_NAMESPACE="${USERID}-cqrs"
   APP_PORT=8080

   # Secret 이름에 userid 추가
   DB_SECRET_NAME="${USERID}-db-credentials"

   POSTGRES_PASSWORD="Passw0rd"
   MONGO_PASSWORD="Passw0rd"

   # Event Hub 설정
   STORAGE_ACCOUNT="${USERID}storage"
   BLOB_CONTAINER="${USERID}-eventhub-checkpoints"
   PLAN_EVENT_HUB_NS="${USERID}-eventhub-plan-ns"
   USAGE_EVENT_HUB_NS="${USERID}-eventhub-usage-ns"
   PLAN_HUB_NAME="${USERID}-mq-plan"
   USAGE_HUB_NAME="${USERID}-mq-usage"

   LOG_FILE="deployment_${NAME}.log"
}

# 애플리케이션 정리
cleanup_application() {
   log "기존 애플리케이션 정리 중..."

   # 기존 ConfigMap, Secret 지우기
   kubectl delete cm $NAME-config -n $APP_NAMESPACE $NAME-command 2>/dev/null || true
   kubectl delete secret eventhub-secret -n $APP_NAMESPACE $NAME-command 2>/dev/null || true
   kubectl delete secret storage-secret -n $APP_NAMESPACE $NAME-command 2>/dev/null || true

   # 기존 deployment 삭제
   kubectl delete deployment -n $APP_NAMESPACE $NAME-command 2>/dev/null || true
   kubectl delete deployment -n $APP_NAMESPACE $NAME-query 2>/dev/null || true

   # deployment가 완전히 삭제될 때까지 대기
   kubectl wait --for=delete deployment/$NAME-command -n $APP_NAMESPACE --timeout=60s 2>/dev/null || true
   kubectl wait --for=delete deployment/$NAME-query -n $APP_NAMESPACE --timeout=60s 2>/dev/null || true
}

# AKS 자격증명 가져오기
setup_aks() {
   # AKS 자격 증명 가져오기
    az aks get-credentials --resource-group $RESOURCE_GROUP --name $AKS_NAME
    check_error "AKS 자격 증명 가져오기 실패"
}

# 애플리케이션 빌드
build_application() {
   log "애플리케이션 빌드 중..."

   # Gradle 빌드
   chmod +x gradlew
   ./gradlew command:clean command:build -x test
   ./gradlew query:clean query:build -x test
   check_error "Gradle 빌드 실패"

   # Dockerfile 생성 - Command 서비스
   cat > Dockerfile-command << EOF
FROM --platform=linux/amd64 eclipse-temurin:17-jdk-alpine
COPY command/build/libs/cqrs-command.jar app.jar
ENTRYPOINT ["java","-jar","/app.jar"]
EOF

   # Dockerfile 생성 - Query 서비스
   cat > Dockerfile-query << EOF
FROM --platform=linux/amd64 eclipse-temurin:17-jdk-alpine
COPY query/build/libs/cqrs-query.jar app.jar
ENTRYPOINT ["java","-jar","/app.jar"]
EOF

   # Docker 이미지 빌드
   docker build -f Dockerfile-command -t ${ACR_NAME}.azurecr.io/telecom/cqrs-command:v1 .
   check_error "Command 서비스 이미지 빌드 실패"

   docker build -f Dockerfile-query -t ${ACR_NAME}.azurecr.io/telecom/cqrs-query:v1 .
   check_error "Query 서비스 이미지 빌드 실패"
}

# 이미지 push
push_images() {
   log "Docker 이미지 푸시 중..."

   # ACR 로그인
   az acr login --name $ACR_NAME
   check_error "ACR 로그인 실패"

   # 이미지 푸시
   docker push ${ACR_NAME}.azurecr.io/telecom/cqrs-command:v1
   check_error "Command 서비스 이미지 푸시 실패"

   docker push ${ACR_NAME}.azurecr.io/telecom/cqrs-query:v1
   check_error "Query 서비스 이미지 푸시 실패"

   # 이미지 태그 확인
   az acr repository list --name $ACR_NAME --output table
   az acr repository show-tags --name $ACR_NAME --repository telecom/cqrs-command --output table
   az acr repository show-tags --name $ACR_NAME --repository telecom/cqrs-query --output table
}

# Database Secret 설정
setup_db_secrets() {
   log "데이터베이스 Secret 설정 중..."

   kubectl delete secret $DB_SECRET_NAME --namespace $DB_NAMESPACE
   kubectl delete secret $DB_SECRET_NAME --namespace $APP_NAMESPACE

   # DB Namespace에 Secret 생성
   kubectl create secret generic $DB_SECRET_NAME \
       --namespace $DB_NAMESPACE \
       --from-literal=postgres-password=$POSTGRES_PASSWORD \
       --from-literal=mongo-password=$MONGO_PASSWORD \
       2>/dev/null || true

   # App Namespace에도 동일한 Secret 생성
   kubectl create secret generic $DB_SECRET_NAME \
       --namespace $APP_NAMESPACE \
       --from-literal=postgres-password=$POSTGRES_PASSWORD \
       --from-literal=mongo-password=$MONGO_PASSWORD \
       2>/dev/null || true

   check_error "데이터베이스 Secret 생성 실패"
}

# 기존 데이터베이스 정리
cleanup_databases() {
   log "기존 데이터베이스 정리 중..."

   # StatefulSet 삭제
   kubectl delete statefulset -n $DB_NAMESPACE $NAME-postgres 2>/dev/null || true
   kubectl delete statefulset -n $DB_NAMESPACE $NAME-mongodb 2>/dev/null || true

   # PVC 삭제 - label에 userid 추가
   kubectl delete pvc -n $DB_NAMESPACE -l "app=postgres,userid=$USERID" 2>/dev/null || true
   kubectl delete pvc -n $DB_NAMESPACE -l "app=mongodb,userid=$USERID" 2>/dev/null || true

   # Service 삭제
   kubectl delete service -n $DB_NAMESPACE $NAME-postgres 2>/dev/null || true
   kubectl delete service -n $DB_NAMESPACE $NAME-mongodb 2>/dev/null || true
}

setup_postgresql() {
    log "PostgreSQL 데이터베이스 설정 중..."

    # PostgreSQL 초기화 스크립트용 ConfigMap 생성
    cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: postgres-init-script
  namespace: $DB_NAMESPACE
data:
  init.sql: |
    CREATE DATABASE telecomdb;
EOF
    check_error "PostgreSQL 초기화 스크립트 ConfigMap 생성 실패"

    # PostgreSQL StatefulSet 및 Service 생성
    cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: $NAME-postgres
  namespace: $DB_NAMESPACE
spec:
  serviceName: "$NAME-postgres"
  replicas: 1
  selector:
    matchLabels:
      app: postgres
      userid: $USERID
  template:
    metadata:
      labels:
        app: postgres
        userid: $USERID
    spec:
      containers:
      - name: postgres
        image: postgres:15
        env:
        - name: POSTGRES_USER
          value: "postgres"
        - name: POSTGRES_PASSWORD
          valueFrom:
            secretKeyRef:
              name: $DB_SECRET_NAME
              key: postgres-password
        - name: PGDATA
          value: /var/lib/postgresql/data/pgdata
        ports:
        - containerPort: 5432
        volumeMounts:
        - name: postgres-data
          mountPath: /var/lib/postgresql/data
          subPath: postgres
        - name: init-script
          mountPath: /docker-entrypoint-initdb.d
        resources:
          requests:
            memory: "256Mi"
            cpu: "250m"
          limits:
            memory: "512Mi"
            cpu: "500m"
      volumes:
      - name: init-script
        configMap:
          name: postgres-init-script
  volumeClaimTemplates:
  - metadata:
      name: postgres-data
    spec:
      accessModes: [ "ReadWriteOnce" ]
      resources:
        requests:
          storage: 10Gi
---
apiVersion: v1
kind: Service
metadata:
  name: $NAME-postgres
  namespace: $DB_NAMESPACE
spec:
  selector:
    app: postgres
    userid: $USERID
  ports:
  - port: 5432
    targetPort: 5432
  type: ClusterIP
EOF
    check_error "PostgreSQL 배포 실패"

    # PostgreSQL Pod가 Ready 상태가 될 때까지 대기
    log "PostgreSQL 준비 상태 대기 중..."
    kubectl wait --for=condition=ready pod -l "app=postgres,userid=$USERID" -n $DB_NAMESPACE --timeout=120s
    check_error "PostgreSQL Pod Ready 상태 대기 실패"

    # 데이터베이스 생성 확인
    log "데이터베이스 생성 확인 중..."
    POD_NAME=$(kubectl get pod -l "app=postgres,userid=$USERID" -n $DB_NAMESPACE -o jsonpath='{.items[0].metadata.name}')

    # 데이터베이스 존재 여부 확인 (10번 시도)
    for i in {1..10}; do
        if kubectl exec $POD_NAME -n $DB_NAMESPACE -- psql -U postgres -lqt | cut -d \| -f 1 | grep -qw telecomdb; then
            log "데이터베이스 'telecomdb' 생성 확인 완료"
            break
        fi
        if [ $i -eq 10 ]; then
            log "Error: 데이터베이스 생성 실패"
            exit 1
        fi
        log "데이터베이스 생성 확인 중... (${i}/10)"
        sleep 5
    done
}

# MongoDB 설정
setup_mongodb() {
   log "MongoDB 데이터베이스 설정 중..."

   # MongoDB 초기화 스크립트 ConfigMap 생성
   cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
 name: mongo-init-script
 namespace: $DB_NAMESPACE
data:
 init-mongo.js: |
   db = db.getSiblingDB('telecomdb');
   db.createUser({
     user: 'telecom',
     pwd: '$MONGO_PASSWORD',
     roles: [{ role: 'readWrite', db: 'telecomdb' }]
   });
EOF

   cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: StatefulSet
metadata:
 name: $NAME-mongodb
 namespace: $DB_NAMESPACE
spec:
 serviceName: "$NAME-mongodb"
 replicas: 1
 selector:
   matchLabels:
     app: mongodb
     userid: $USERID
 template:
   metadata:
     labels:
       app: mongodb
       userid: $USERID
   spec:
     containers:
     - name: mongodb
       image: mongo:8.0.3
       env:
       - name: MONGO_INITDB_ROOT_USERNAME
         value: "root"
       - name: MONGO_INITDB_ROOT_PASSWORD
         valueFrom:
           secretKeyRef:
             name: $DB_SECRET_NAME
             key: mongo-password
       - name: MONGO_INITDB_DATABASE
         value: "telecomdb"
       - name: MONGO_INITDB_USERNAME
         value: "telecom"
       - name: MONGO_INITDB_PASSWORD
         valueFrom:
            secretKeyRef:
              name: $DB_SECRET_NAME
              key: mongo-password
       ports:
       - containerPort: 27017
       volumeMounts:
       - name: mongodb-data
         mountPath: /data/db
         subPath: mongo
       - name: init-script
         mountPath: /docker-entrypoint-initdb.d
     volumes:
     - name: init-script
       configMap:
         name: mongo-init-script
 volumeClaimTemplates:
 - metadata:
     name: mongodb-data
   spec:
     accessModes: [ "ReadWriteOnce" ]
     resources:
       requests:
         storage: 10Gi
---
apiVersion: v1
kind: Service
metadata:
 name: $NAME-mongodb
 namespace: $DB_NAMESPACE
spec:
 selector:
   app: mongodb
   userid: $USERID
 ports:
 - port: 27017
   targetPort: 27017
 type: ClusterIP
EOF
   check_error "MongoDB 배포 실패"
}

# Database 설정
setup_databases() {
   log "데이터베이스 설정 중..."

   # Namespace 생성
   kubectl create namespace $DB_NAMESPACE 2>/dev/null || true
   kubectl create namespace $APP_NAMESPACE 2>/dev/null || true

   # Secret 설정
   setup_db_secrets

   # 기존 데이터베이스 정리
   cleanup_databases

   # 데이터베이스 배포
   setup_postgresql
   setup_mongodb

   # 데이터베이스가 Ready 상태가 될 때까지 대기
   log "데이터베이스 준비 상태 대기 중..."
   kubectl wait --for=condition=ready pod -l "app=postgres,userid=$USERID" -n $DB_NAMESPACE --timeout=120s
   kubectl wait --for=condition=ready pod -l "app=mongodb,userid=$USERID" -n $DB_NAMESPACE --timeout=120s
}

# Event Hub 네임스페이스 및 이벤트 허브 생성
setup_event_hub() {
   log "Event Hub 확인 중..."

   # Plan Event Hub 네임스페이스 생성/확인
   EXISTING_PLAN_NS=$(az eventhubs namespace show \
       --name $PLAN_EVENT_HUB_NS \
       --resource-group $RESOURCE_GROUP \
       --query name \
       --output tsv 2>/dev/null)

   if [ -z "$EXISTING_PLAN_NS" ]; then
       log "Plan Event Hub 네임스페이스 생성 중... (약 2-3분 소요)"
       az eventhubs namespace create \
           --name $PLAN_EVENT_HUB_NS \
           --resource-group $RESOURCE_GROUP \
           --location $LOCATION \
           --sku Basic
       check_error "Plan Event Hub 네임스페이스 생성 실패"
   else
       log "기존 Plan Event Hub 네임스페이스 사용"
   fi

   # Usage Event Hub 네임스페이스 생성/확인
   EXISTING_USAGE_NS=$(az eventhubs namespace show \
       --name $USAGE_EVENT_HUB_NS \
       --resource-group $RESOURCE_GROUP \
       --query name \
       --output tsv 2>/dev/null)

   if [ -z "$EXISTING_USAGE_NS" ]; then
       log "Usage Event Hub 네임스페이스 생성 중... (약 2-3분 소요)"
       az eventhubs namespace create \
           --name $USAGE_EVENT_HUB_NS \
           --resource-group $RESOURCE_GROUP \
           --location $LOCATION \
           --sku Basic
       check_error "Usage Event Hub 네임스페이스 생성 실패"
   else
       log "기존 Usage Event Hub 네임스페이스 사용"
   fi

   # Plan Event Hub 생성
   EXISTING_PLAN_HUB=$(az eventhubs eventhub show \
       --name $PLAN_HUB_NAME \
       --namespace-name $PLAN_EVENT_HUB_NS \
       --resource-group $RESOURCE_GROUP \
       --query name \
       --output tsv 2>/dev/null)

   if [ -z "$EXISTING_PLAN_HUB" ]; then
       log "Plan Event Hub 생성 중..."
       az eventhubs eventhub create \
           --name $PLAN_HUB_NAME \
           --namespace-name $PLAN_EVENT_HUB_NS \
           --resource-group $RESOURCE_GROUP \
           --partition-count 1 \
           --cleanup-policy Delete \
           --retention-time 24
       check_error "Plan Event Hub 생성 실패"
   fi

   # Usage Event Hub 생성
   EXISTING_USAGE_HUB=$(az eventhubs eventhub show \
       --name $USAGE_HUB_NAME \
       --namespace-name $USAGE_EVENT_HUB_NS \
       --resource-group $RESOURCE_GROUP \
       --query name \
       --output tsv 2>/dev/null)

   if [ -z "$EXISTING_USAGE_HUB" ]; then
       log "Usage Event Hub 생성 중..."
       az eventhubs eventhub create \
           --name $USAGE_HUB_NAME \
           --namespace-name $USAGE_EVENT_HUB_NS \
           --resource-group $RESOURCE_GROUP \
           --partition-count 1 \
           --cleanup-policy Delete \
           --retention-time 24
       check_error "Usage Event Hub 생성 실패"
   fi

   log "Event Hub 연결 문자열 가져오는 중..."
   # Plan Event Hub 연결 문자열 가져오기
   PLAN_CONNECTION_STRING=$(az eventhubs namespace authorization-rule keys list \
       --resource-group $RESOURCE_GROUP \
       --namespace-name $PLAN_EVENT_HUB_NS \
       --name RootManageSharedAccessKey \
       --query primaryConnectionString -o tsv)
   check_error "Plan Event Hub 연결 문자열 가져오기 실패"

   # Usage Event Hub 연결 문자열 가져오기
   USAGE_CONNECTION_STRING=$(az eventhubs namespace authorization-rule keys list \
       --resource-group $RESOURCE_GROUP \
       --namespace-name $USAGE_EVENT_HUB_NS \
       --name RootManageSharedAccessKey \
       --query primaryConnectionString -o tsv)
   check_error "Usage Event Hub 연결 문자열 가져오기 실패"

   # Secret으로 저장
   log "Event Hub 연결 정보를 Secret으로 저장 중..."
   kubectl create secret generic eventhub-secret \
       --namespace $APP_NAMESPACE \
       --from-literal=plan-connection-string="$PLAN_CONNECTION_STRING" \
       --from-literal=usage-connection-string="$USAGE_CONNECTION_STRING" \
       --from-literal=plan-hub-name="$PLAN_HUB_NAME" \
       --from-literal=usage-hub-name="$USAGE_HUB_NAME" \
       --from-literal=consumer-group="\$Default" \
       2>/dev/null || true
   check_error "Event Hub Secret 저장 실패"

   log "Event Hub 설정 완료"
}

#Event Hub가 사용하는 Blob Storage 설정
setup_storage() {
    log "Storage Account 및 Blob Container 설정 중..."

    # Storage Account가 없으면 생성
    STORAGE_EXISTS=$(az storage account show \
        --name $STORAGE_ACCOUNT \
        --resource-group $RESOURCE_GROUP \
        --query name \
        --output tsv 2>/dev/null)

    if [ -z "$STORAGE_EXISTS" ]; then
        az storage account create \
            --name $STORAGE_ACCOUNT \
            --resource-group $RESOURCE_GROUP \
            --location $LOCATION \
            --sku Standard_LRS
        check_error "Storage Account 생성 실패"
    fi

    # 연결 문자열 얻기
    STORAGE_CONNECTION_STRING=$(az storage account show-connection-string \
        --name $STORAGE_ACCOUNT \
        --resource-group $RESOURCE_GROUP \
        --query connectionString \
        --output tsv)
    check_error "Storage 연결 문자열 가져오기 실패"

    # Blob Container 생성
    az storage container create \
        --name $BLOB_CONTAINER \
        --connection-string "$STORAGE_CONNECTION_STRING" \
        2>/dev/null || true

    # Secret으로 저장
    kubectl create secret generic storage-secret \
        --namespace $APP_NAMESPACE \
        --from-literal=connection-string="$STORAGE_CONNECTION_STRING" \
        2>/dev/null || true
    check_error "Storage Secret 저장 실패"
}

deploy_application() {
   log "애플리케이션 배포를 위한 ConfigMap 생성 중..."

   # ConfigMap 생성
   cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: $NAME-config
  namespace: $APP_NAMESPACE
data:
  APP_NAME: "cqrs"
  SERVER_PORT: "8080"

  # PostgreSQL 설정
  POSTGRES_HOST: "${NAME}-postgres.${DB_NAMESPACE}.svc.cluster.local"
  POSTGRES_PORT: "5432"
  POSTGRES_DB: "telecomdb"
  POSTGRES_USER: "postgres"

  # MongoDB 설정
  MONGODB_HOST: "${NAME}-mongodb.${DB_NAMESPACE}.svc.cluster.local"
  MONGODB_PORT: "27017"
  MONGODB_DB: "telecomdb"
  MONGODB_USER: "root"

  # JPA 설정
  JPA_DDL_AUTO: "update"
  JPA_SHOW_SQL: "false"

  # Event Hub 설정
  EVENT_HUB_PLAN_NS: "${PLAN_EVENT_HUB_NS}"
  EVENT_HUB_USAGE_NS: "${USAGE_EVENT_HUB_NS}"
  EVENT_HUB_PLAN_NAME: "${PLAN_HUB_NAME}"
  EVENT_HUB_USAGE_NAME: "${USAGE_HUB_NAME}"
EOF

   log "애플리케이션 배포 중..."

   # Command 서비스 Deployment 부분만 수정
   cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
 name: $NAME-command
 namespace: $APP_NAMESPACE
spec:
 replicas: 1
 selector:
   matchLabels:
     app: command-service
     userid: $USERID
 template:
   metadata:
     labels:
       app: command-service
       userid: $USERID
   spec:
     containers:
     - name: command-service
       image: ${ACR_NAME}.azurecr.io/telecom/cqrs-command:v1
       imagePullPolicy: Always
       ports:
       - containerPort: 8080
       envFrom:
       - configMapRef:
           name: $NAME-config
       env:
       - name: POSTGRES_PASSWORD
         valueFrom:
           secretKeyRef:
             name: $DB_SECRET_NAME
             key: postgres-password
       - name: STORAGE_CONNECTION_STRING
         valueFrom:
           secretKeyRef:
             name: storage-secret
             key: connection-string
       # Event Hub 연결 문자열 분리
       - name: EVENT_HUB_PLAN_CONNECTION_STRING
         valueFrom:
           secretKeyRef:
             name: eventhub-secret
             key: plan-connection-string
       - name: EVENT_HUB_USAGE_CONNECTION_STRING
         valueFrom:
           secretKeyRef:
             name: eventhub-secret
             key: usage-connection-string
       - name: EVENT_HUB_NAMESPACE_PLAN
         value: "${PLAN_EVENT_HUB_NS}"
       - name: EVENT_HUB_NAMESPACE_USAGE
         value: "${USAGE_EVENT_HUB_NS}"
       resources:
         requests:
           cpu: "250m"
           memory: "512Mi"
         limits:
           cpu: "500m"
           memory: "1024Mi"

---
apiVersion: v1
kind: Service
metadata:
  name: $NAME-command
  namespace: $APP_NAMESPACE
spec:
  selector:
    app: command-service
    userid: $USERID
  ports:
  - port: 8080
    targetPort: 8080
  type: LoadBalancer
---
apiVersion: apps/v1
kind: Deployment
metadata:
 name: $NAME-query
 namespace: $APP_NAMESPACE
spec:
 replicas: 1
 selector:
   matchLabels:
     app: query-service
     userid: $USERID
 template:
   metadata:
     labels:
       app: query-service
       userid: $USERID
   spec:
     containers:
     - name: query-service
       image: ${ACR_NAME}.azurecr.io/telecom/cqrs-query:v1
       imagePullPolicy: Always
       ports:
       - containerPort: 8080
       envFrom:
       - configMapRef:
           name: $NAME-config
       env:
       - name: MONGODB_PASSWORD
         valueFrom:
           secretKeyRef:
             name: $DB_SECRET_NAME
             key: mongo-password
       - name: STORAGE_CONNECTION_STRING
         valueFrom:
            secretKeyRef:
              name: storage-secret
              key: connection-string
       - name: EVENT_HUB_PLAN_CONNECTION_STRING
         valueFrom:
           secretKeyRef:
             name: eventhub-secret
             key: plan-connection-string
       - name: EVENT_HUB_USAGE_CONNECTION_STRING
         valueFrom:
           secretKeyRef:
             name: eventhub-secret
             key: usage-connection-string
       - name: EVENT_HUB_NAMESPACE_PLAN
         value: "${PLAN_EVENT_HUB_NS}"
       - name: EVENT_HUB_NAMESPACE_USAGE
         value: "${USAGE_EVENT_HUB_NS}"
       - name: BLOB_CONTAINER
         value: "${BLOB_CONTAINER}"
       resources:
         requests:
           cpu: "250m"
           memory: "512Mi"
         limits:
           cpu: "500m"
           memory: "1024Mi"

---
apiVersion: v1
kind: Service
metadata:
  name: $NAME-query
  namespace: $APP_NAMESPACE
spec:
  selector:
    app: query-service
    userid: $USERID
  ports:
  - port: 8080
    targetPort: 8080
  type: LoadBalancer
EOF

   # Deployment가 성공적으로 생성되었는지 확인
   kubectl wait --for=condition=available deployment/$NAME-command -n $APP_NAMESPACE --timeout=300s
   check_error "Command 서비스 Deployment 대기 실패"

   kubectl wait --for=condition=available deployment/$NAME-query -n $APP_NAMESPACE --timeout=300s
   check_error "Query 서비스 Deployment 대기 실패"

   # Service의 External IP를 얻기 위해 대기
   log "Service External IP 대기 중..."
   for i in {1..30}; do
     COMMAND_IP=$(kubectl get svc $NAME-command -n $APP_NAMESPACE -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null)
     QUERY_IP=$(kubectl get svc $NAME-query -n $APP_NAMESPACE -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null)

     if [ ! -z "$COMMAND_IP" ] && [ ! -z "$QUERY_IP" ]; then
       break
     fi
     log "LoadBalancer IP 대기 중... (${i}/30)"
     sleep 10
   done

   if [ -z "$COMMAND_IP" ] || [ -z "$QUERY_IP" ]; then
     log "Error: Service External IP를 얻는데 실패했습니다"
     exit 1
   fi
}

# Completion 메시지 출력
print_completion_message() {
   log "=== 배포 완료 ==="
   log "Command Service URL: http://$COMMAND_IP:8080/swagger-ui.html"
   log "Query Service URL: http://$QUERY_IP:8080/swagger-ui.html"
}

# 메인 실행 함수
main() {
	log "CQRS 패턴 실습환경 구성을 시작합니다..."

	# 사전 체크
	check_prerequisites

	# 환경 변수 설정
	setup_environment "$1"
	cleanup_application

	# AKS 권한 취득
	setup_aks

	# ACR pull 권한 설정
	setup_acr_permission

	# 리소스 생성 및 애플리케이션 배포
	build_application
	push_images

	# Database 배포
	setup_databases

	# Event Hub 설정 (데이터베이스 다음, 애플리케이션 배포 전)
	setup_event_hub
	setup_storage

	# 기존 애플리케이션 정리 후 재배포
	deploy_application

	log "모든 리소스가 성공적으로 생성되었습니다."

	# 결과 출력
	print_completion_message
}

# 스크립트 시작
if [ $# -ne 1 ]; then
    print_usage
    exit 1
fi

# userid 유효성 검사
if [[ ! $1 =~ ^[a-z0-9]+$ ]]; then
    echo "Error: userid는 영문 소문자와 숫자만 사용할 수 있습니다."
    exit 1
fi

main "$1"