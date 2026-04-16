pipeline {
    agent any
    stages {
        stage('Outer') {
            stages {
                stage('Inner Compile') {
                    steps {
                        echo "TRACEPARENT: ${env.TRACEPARENT}"
                        sh 'sleep 2'
                    }
                }
                stage('Inner Test') {
                    steps {
                        echo "TRACEPARENT: ${env.TRACEPARENT}"
                        sh 'sleep 2'
                    }
                }
            }
        }
    }
}
