pipeline {
    agent any
    stages {
        stage('Deploy') {
            steps {
                echo "Before: ${env.TRACEPARENT}"
                withEnv(['MY_VAR=hello']) {
                    echo "Inside: ${env.TRACEPARENT}"
                    sh 'echo TRACEPARENT=$TRACEPARENT MY_VAR=$MY_VAR'
                }
                echo "After: ${env.TRACEPARENT}"
            }
        }
    }
}
