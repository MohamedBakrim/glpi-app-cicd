pipeline {
    // The controller image (jenkins/Dockerfile) has the docker CLI + compose plugin
    // and the daemon socket mounted. If you later add dedicated agents, switch this
    // to `agent { label 'docker' }`.
    agent any

    options {
        timestamps()
        timeout(time: 60, unit: 'MINUTES')
        buildDiscarder(logRotator(numToKeepStr: '30', artifactNumToKeepStr: '10'))
        // Two builds must never share the same image tags / compose project.
        disableConcurrentBuilds()
    }

    parameters {
        string(name: 'GLPI_VERSION', defaultValue: '12.0.2',
               description: 'Upstream GLPI tag to vendor (must exist on github.com/glpi-project/glpi)')
    }

    environment {
        // Must match the Helm chart's image.repository / nginx.image.repository
        // so a bump only changes tags. Switch to GHCR only together with an
        // imagePullSecret in the chart.
        REGISTRY        = 'docker.io'
        IMAGE_NAMESPACE = 'mdbak'
        PHP_IMAGE       = "${REGISTRY}/${IMAGE_NAMESPACE}/glpi-php-fpm"
        WEB_IMAGE       = "${REGISTRY}/${IMAGE_NAMESPACE}/glpi-nginx"

        GLPI_VERSION    = "${params.GLPI_VERSION ?: '12.0.2'}"
        // Immutable, traceable tag. Never deploy `latest`.
        TAG             = "${GLPI_VERSION}-b${env.BUILD_NUMBER}"
        SMOKE_PROJECT   = "glpi-ci-${env.BUILD_NUMBER}"
        TRIVY_SEVERITY  = 'HIGH,CRITICAL'

        // GitOps repository contract — matches the chart's values structure.
        // The pipeline writes digest-pinned tags: "12.0.2@sha256:..." like the
        // chart already does, so a moved tag can never change what runs.
        GITOPS_REPO_URL    = 'https://github.com/MohamedBakrim/glpi-gitops-cicd.git'
        GITOPS_VALUES_FILE = 'values-prod.yaml'
        YQ_PHP_REPO        = '.image.repository'
        YQ_PHP_TAG         = '.image.tag'
        YQ_WEB_REPO        = '.nginx.image.repository'
        YQ_WEB_TAG         = '.nginx.image.tag'

        ARGOCD_SERVER = 'argocd.medbak.xyz'
        ARGOCD_APP    = 'glpi'
        PUBLIC_URL    = 'https://glpi.medbak.xyz'
    }

    stages {
        stage('Prepare') {
            steps { sh './ci/prepare.sh' }
        }

        stage('Build images') {
            steps { sh './ci/build.sh' }
        }

        stage('Smoke test') {
            steps { sh './ci/smoke.sh' }
            post {
                always {
                    archiveArtifacts artifacts: '.ci-out/**', allowEmptyArchive: true, fingerprint: true
                }
            }
        }

        stage('Scan') {
            steps { sh './ci/scan.sh' }
            post {
                always {
                    archiveArtifacts artifacts: '.ci-out/trivy-*.txt', allowEmptyArchive: true
                }
            }
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
                    sh './ci/publish.sh'
                }
            }
        }

        stage('GitOps bump') {
            when { branch 'main' }
            steps {
                withCredentials([string(credentialsId: 'gitops-token', variable: 'GITOPS_TOKEN')]) {
                    sh './ci/bump.sh'
                }
            }
        }

        stage('Verify rollout') {
            when { branch 'main' }
            steps {
                withCredentials([string(credentialsId: 'argocd-token', variable: 'ARGOCD_TOKEN')]) {
                    sh './ci/verify.sh'
                }
            }
        }
    }

    post {
        always {
            // Guarded: a build that died before checkout has no workspace to clean.
            sh 'if [ -f ci/cleanup.sh ]; then ./ci/cleanup.sh; fi'
        }
        unsuccessful {
            echo "See the archived .ci-out/compose.log, php-errors.log and trivy-*.txt"
        }
    }
}
