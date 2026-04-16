pipeline {
    agent any
    stages {
        stage('Risky') {
            steps {
                script {
                    try {
                        sh 'exit 1'
                    } catch (err) {
                        echo "Caught: ${err}. Recovering..."
                        sh 'sleep 1'
                    }
                }
            }
        }
        stage('Verify') {
            steps {
                echo "TRACEPARENT: ${env.TRACEPARENT}"
                echo 'Build succeeded despite caught error'
            }
        }
    }
}
