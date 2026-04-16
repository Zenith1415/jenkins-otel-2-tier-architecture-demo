pipeline {
    agent any
    stages {
        stage('Long Compile') {
            steps {
                echo "TRACEPARENT: ${env.TRACEPARENT}"
                sh 'sleep 65'
            }
        }
    }
}
