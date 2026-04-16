pipeline {
    agent any
    stages {
        stage('Setup') {
            steps { sh 'sleep 1' }
        }
        stage('Deploy') {
            steps { sh 'exit 1' }
        }
        stage('Verify') {
            steps { echo 'never runs' }
        }
    }
}
