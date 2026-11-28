pipeline {
    agent any

    options {
        timestamps()
        timeout(time: 60, unit: 'MINUTES')
        buildDiscarder(logRotator(numToKeepStr: '30', artifactNumToKeepStr: '10'))
        disableConcurrentBuilds()
    }

    parameters {
        string(name: 'GLPI_VERSION', defaultValue: '12.0.2',
               description: 'Upstream GLPI tag to vendor (must exist on github.com/glpi-project/glpi)')
    }

    environment {
        REGISTRY        = 'docker.io'
        IMAGE_NAMESPACE = 'mdbak'
        PHP_IMAGE       = "${REGISTRY}/${IMAGE_NAMESPACE}/glpi-php-fpm"
        WEB_IMAGE       = "${REGISTRY}/${IMAGE_NAMESPACE}/glpi-nginx"

        GLPI_VERSION    = "${params.GLPI_VERSION ?: '12.0.2'}"
        TAG             = "${GLPI_VERSION}-b${env.BUILD_NUMBER}"
        SMOKE_PROJECT   = "glpi-ci-${env.BUILD_NUMBER}"
        TRIVY_SEVERITY  = 'HIGH,CRITICAL'

        GITOPS_REPO_URL    = 'https://github.com/MohamedBakrim/glpi-gitops-cicd.git'
        GITOPS_VALUES_FILE = 'values-prod.yaml'
    }

    stages {
        stage('Prepare') {
            steps { sh 'bash ./ci/prepare.sh' }
        }

        stage('Build images') {
            steps { sh 'bash ./ci/build.sh' }
        }

        stage('Smoke test') {
            steps { sh 'bash ./ci/smoke.sh' }
        }

        stage('Scan') {
            steps { sh 'bash ./ci/scan.sh' }
        }

        stage('Publish') {
            // Never publish from a pull request — only from the mainline.
            when { branch 'main' }
            steps {
                withCredentials([usernamePassword(
                    credentialsId: 'registry-creds',
                    usernameVariable: 'REGISTRY_USER',
                    passwordVariable: 'REGISTRY_PASSWORD'
                )]) {
                    sh 'bash ./ci/publish.sh'
                }
            }
        }

        stage('Update GitOps values') {
            when { branch 'main' }
            steps {
                withCredentials([string(credentialsId: 'gitops-token', variable: 'GITOPS_TOKEN')]) {
                    sh 'bash ./ci/bump.sh'
                }
            }
        }
    }

    post {
        always {
            sh 'if [ -f ci/cleanup.sh ]; then bash ./ci/cleanup.sh; fi'
            archiveArtifacts artifacts: '.ci-out/**', allowEmptyArchive: true
        }
        unsuccessful {
            echo "See the archived .ci-out/compose.log, php-errors.log and trivy-*.txt"
        }
    }
}
