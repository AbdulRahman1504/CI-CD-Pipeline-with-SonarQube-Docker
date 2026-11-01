pipeline {
    agent any

    // Fires when the GitHub webhook (http://<EC2_IP>:8080/github-webhook/) hits Jenkins
    triggers {
        githubPush()
    }

    options {
        timestamps()
        timeout(time: 30, unit: 'MINUTES')
        disableConcurrentBuilds()
    }

    environment {
        // CHANGE THIS to your DockerHub username/repo
        IMAGE_NAME     = 'abdulrahman1504/cicdproject'
        IMAGE_TAG      = "${env.BUILD_NUMBER}"
        CONTAINER_NAME = 'cicd-demo-app'
        APP_PORT       = '5000'
    }

    stages {
        stage('Checkout') {
            steps {
                checkout scm
            }
        }

        stage('Build & Test') {
            steps {
                sh '''
                    python3 -m venv venv
                    . venv/bin/activate
                    pip install --quiet -r requirements.txt
                    pytest --cov=app --cov-report=xml:coverage.xml --cov-report=term -v
                '''
            }
        }

        stage('SonarQube Analysis') {
            steps {
                script {
                    // Tool name configured in Manage Jenkins > Tools > SonarQube Scanner
                    def scannerHome = tool 'sonar-scanner'
                    // Server name configured in Manage Jenkins > System > SonarQube servers
                    withSonarQubeEnv('sonarqube') {
                        sh "${scannerHome}/bin/sonar-scanner"
                    }
                }
            }
        }

    

        stage('Docker Build') {
            steps {
                sh '''
                    docker build -t ${IMAGE_NAME}:${IMAGE_TAG} -t ${IMAGE_NAME}:latest .
                '''
            }
        }

        stage('Push to DockerHub') {
            steps {
                withCredentials([usernamePassword(credentialsId: 'dockerhub-creds',
                                                  usernameVariable: 'DH_USER',
                                                  passwordVariable: 'DH_PASS')]) {
                    sh '''
                        echo "$DH_PASS" | docker login -u "$DH_USER" --password-stdin
                        docker push ${IMAGE_NAME}:${IMAGE_TAG}
                        docker push ${IMAGE_NAME}:latest
                        docker logout
                    '''
                }
            }
        }

        stage('Deploy') {
            steps {
                sh '''
                    docker rm -f ${CONTAINER_NAME} || true
                    docker run -d --name ${CONTAINER_NAME} --restart unless-stopped \
                        -p ${APP_PORT}:5000 ${IMAGE_NAME}:${IMAGE_TAG}
                    sleep 5
                    curl -fsS http://localhost:${APP_PORT}/health
                '''
            }
        }
    }

    post {
        always {
            sh 'docker image prune -f || true'
        }
        success {
            echo "Deployed ${IMAGE_NAME}:${IMAGE_TAG}"
        }
        failure {
            echo 'Pipeline failed - check the failing stage above.'
        }
    }
}
