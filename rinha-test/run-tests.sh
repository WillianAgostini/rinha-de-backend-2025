#!/usr/bin/env bash

startContainers() {
    pushd ../payment-processor > /dev/null
        docker compose up --build -d 1> /dev/null 2>&1
    popd > /dev/null
    pushd ../participantes/$1 > /dev/null
        services=$(docker compose config --services | wc -l)
        echo "" > docker-compose.logs
        nohup docker compose up --build >> docker-compose.logs &
    popd > /dev/null
    #expectedServicesUp=$(( services + 4 ))
    #servicesUp=$(docker ps | grep ' Up ' | wc -l)
}

stopContainers() {
    pushd ../participantes/$1
        docker compose down -v --remove-orphans
        docker compose rm -s -v -f
    popd > /dev/null
    pushd ../payment-processor > /dev/null
        docker compose down --volumes > /dev/null
    popd > /dev/null
}

MAX_REQUESTS=550

while true; do
    for directory in ../participantes/*; do
    (
        git pull
        participant=$(echo $directory | sed -e 's/..\/participantes\///g' -e 's/\///g')
        echo "participant: $participant"

        
        testedFile="$directory/partial-results.json"

        if ! test -f $testedFile; then
            touch $testedFile
            echo "executing test for $participant..."
            stopContainers $participant
            startContainers $participant
            
            success=1
            max_attempts=15
            attempt=1
            while [ $success -ne 0 ] && [ $max_attempts -ge $attempt ]; do
                curl -f -s http://localhost:9999/payments-summary
                success=$?
                echo "tried $attempt out of $max_attempts..."
                sleep 5
                ((attempt++))
            done

            if [ $success -eq 0 ]; then
                echo "" > $directory/k6.logs
                k6 run -e MAX_REQUESTS=$MAX_REQUESTS -e PARTICIPANT=$participant --log-output=file=$directory/k6.logs rinha.js
                stopContainers $participant
                echo "======================================="
                echo "working on $participant"
                sed -i '1001,$d' $directory/docker-compose.logs
                sed -i '1001,$d' $directory/k6.logs
                echo "log truncated at line 1000" >> $directory/docker-compose.logs
                echo "log truncated at line 1000" >> $directory/k6.logs
            else
                stopContainers $participant
                echo "[$(date)] Seu backend não respondeu nenhuma das $max_attempts tentativas de GET para http://localhost:9999/payments-summary. Teste abortado." > $directory/test.logs
                echo "Could not get a successful response from backend... aborting test for $participant"
            fi

            git add $directory
            git commit -m "add $participant's partial result"
            git push

        else
            echo "skipping $participant"
        fi
    )
    done

    date
    echo "generating results preview..."
    
    echo -e "# Prévia do Resultados da Rinha de Backend 2025" > ../PREVIA_RESULTADOS.md
    echo -e "Atualizado em **$(date)** (**$(ls ../participantes | wc -l)** resultados)" >> ../PREVIA_RESULTADOS.md
    echo -e "*Testes executados com MAX_REQUESTS=$MAX_REQUESTS*."
    echo -e "\n" >> ../PREVIA_RESULTADOS.md
    echo -e "| participante | p99 | bônus por desempenho (%) | multa ($) | lucro | submissão |" >> ../PREVIA_RESULTADOS.md
    echo -e "| -- | -- | -- | -- | -- | -- |" >> ../PREVIA_RESULTADOS.md

    for partialResult in ../participantes/*/partial-results.json; do
    (
        participant=$(echo $partialResult | sed -e 's/..\/participantes\///g' -e 's/\///g' -e 's/partial\-results\.json//g')
        link="https://github.com/zanfranceschi/rinha-de-backend-2025/tree/main/participantes/$participant"
        
        if [ -s $partialResult ]; then
            cat $partialResult | jq -r '(["|", .participante, "|", .p99.valor, "|", .p99.bonus, "|", .multa.total, "|", .total_liquido, "|", "['$participant']('$link')"]) | @tsv' >> ../PREVIA_RESULTADOS.md
        fi
    )

    git pull
    git add ../PREVIA_RESULTADOS.md
    git commit -m "previa resultados @ $(date)"
    git push
    done
    echo "$(date) - waiting some time until next round..."
    sleep 300
done
