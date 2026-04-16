pipeline {
    agent any
    stages {
        stage('Checkout') {
            steps {
                echo "TRACEPARENT: ${env.TRACEPARENT}"
                sh 'sleep 2'
            }
        }
        stage('Build') {
            steps {
                echo "TRACEPARENT: ${env.TRACEPARENT}"
                sh 'sleep 3'
            }
        }
        stage('Test') {
            steps {
                echo "TRACEPARENT: ${env.TRACEPARENT}"
                sh 'sleep 2'
            }
        }
    }
}
