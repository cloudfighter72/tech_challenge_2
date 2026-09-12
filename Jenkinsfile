    environment {
        AWS_REGION   = 'us-east-2'
        ECR_REPO     = 'hello-world'
        CLUSTER_NAME = 'tc2-eks'
        NAMESPACE    = 'hello-world'
        RELEASE      = 'hello-world'
        IMAGE_TAG    = "${env.BUILD_NUMBER}"
    }

    stages {
        stage('Resolve Account') {
            steps {
                script {
                    env.AWS_ACCOUNT = sh(
                        script: 'aws sts get-caller-identity --query Account --output text',
                        returnStdout: true
                    ).trim()
                    env.REGISTRY = "${env.AWS_ACCOUNT}.dkr.ecr.${env.AWS_REGION}.amazonaws.com"
                    env.IMAGE    = "${env.REGISTRY}/${env.ECR_REPO}"
                }
            }
        }