pipeline {
    agent any
    stages {
        stage('Quick') {
            steps {
                echo "Build ${env.BUILD_NUMBER} TRACEPARENT: ${env.TRACEPARENT}"
                sh 'sleep 1'
            }
        }
    }
}
