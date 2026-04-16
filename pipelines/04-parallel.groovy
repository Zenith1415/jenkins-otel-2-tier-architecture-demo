pipeline {
    agent any
    stages {
        stage('Parallel Tests') {
            parallel {
                stage('Unit') {
                    steps {
                        echo "TRACEPARENT: ${env.TRACEPARENT}"
                        sh 'sleep 3'
                    }
                }
                stage('Integration') {
                    steps {
                        echo "TRACEPARENT: ${env.TRACEPARENT}"
                        sh 'sleep 4'
                    }
                }
                stage('Lint') {
                    steps {
                        echo "TRACEPARENT: ${env.TRACEPARENT}"
                        sh 'sleep 2'
                    }
                }
            }
        }
    }
}
