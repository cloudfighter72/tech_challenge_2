pipeline {
    agent any

    environment {
        AWS_REGION   = 'us-east-2'
        AWS_ACCOUNT  = '185196963048'          // <-- your account id
        ECR_REPO     = 'hello-world'
        CLUSTER_NAME = 'tc2-eks'
        NAMESPACE    = 'hello-world'
        RELEASE      = 'hello-world'
        REGISTRY     = "${AWS_ACCOUNT}.dkr.ecr.${AWS_REGION}.amazonaws.com"
        IMAGE        = "${REGISTRY}/${ECR_REPO}"
        // Build-number tags, never bare 'latest' - rollbacks need an address.
        IMAGE_TAG    = "${env.BUILD_NUMBER}"
    }

    options {
        timestamps()
        buildDiscarder(logRotator(numToKeepStr: '20'))
        timeout(time: 20, unit: 'MINUTES')
    }

    stages {
        stage('Checkout') {
            steps {
                checkout scm
                sh 'git log -1 --oneline'
            }
        }

        stage('Build Image') {
            steps {
                sh '''
                    docker build -t ${IMAGE}:${IMAGE_TAG} -t ${IMAGE}:latest ./app
                    docker images | grep ${ECR_REPO}
                '''
            }
        }

        stage('Smoke Test') {
            // Fail before anything reaches the registry.
            steps {
                sh '''
                    docker rm -f smoke-${BUILD_NUMBER} 2>/dev/null || true
                    docker run -d --name smoke-${BUILD_NUMBER} -p 18080:8080 ${IMAGE}:${IMAGE_TAG}
                    sleep 5
                    curl -fsS http://localhost:18080/healthz
                    curl -fsS http://localhost:18080/ | grep -q "Hello, World!"
                    echo "smoke test passed"
                '''
            }
            post {
                always {
                    sh 'docker rm -f smoke-${BUILD_NUMBER} 2>/dev/null || true'
                }
            }
        }

        stage('Push to ECR') {
            steps {
                // Auth comes from the EC2 instance profile - no stored keys.
                sh '''
                    aws ecr get-login-password --region ${AWS_REGION} \
                      | docker login --username AWS --password-stdin ${REGISTRY}
                    docker push ${IMAGE}:${IMAGE_TAG}
                    docker push ${IMAGE}:latest
                '''
            }
        }

        stage('Configure kubectl') {
            steps {
                sh '''
                    aws eks update-kubeconfig --name ${CLUSTER_NAME} --region ${AWS_REGION}
                    kubectl get nodes
                '''
            }
        }

        stage('Deploy with Helm') {
            steps {
                // upgrade --install is idempotent: first run and hundredth run
                // are the same command.
                sh '''
                    helm upgrade --install ${RELEASE} ./helm/hello-world \
                      --namespace ${NAMESPACE} --create-namespace \
                      --set image.repository=${IMAGE} \
                      --set image.tag=${IMAGE_TAG} \
                      --set env.APP_VERSION=build-${BUILD_NUMBER} \
                      --wait --timeout 5m
                '''
            }
        }

        stage('Verify Rollout') {
            steps {
                sh '''
                    kubectl rollout status deploy/${RELEASE} -n ${NAMESPACE} --timeout=300s
                    kubectl get pods,svc,ingress,hpa -n ${NAMESPACE}
                    echo "URL: http://$(kubectl get ingress ${RELEASE} -n ${NAMESPACE} \
                      -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')"
                '''
            }
        }
    }

    post {
        always {
            // Jenkins build disks fill up fast otherwise.
            sh 'docker rmi ${IMAGE}:${IMAGE_TAG} ${IMAGE}:latest 2>/dev/null || true'
        }
        success {
            echo "Deployed ${IMAGE}:${IMAGE_TAG} to ${CLUSTER_NAME}"
        }
        failure {
            sh 'kubectl get events -n ${NAMESPACE} --sort-by=.lastTimestamp | tail -20 || true'
        }
    }
}
