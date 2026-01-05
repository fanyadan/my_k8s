FROM slurm-local:dev

ENV DEBIAN_FRONTEND=noninteractive \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

# Add sshd for MPI Operator worker pods.
# Use HTTPS for apt repos (HTTP/80 has been flaky from the Docker build environment).
RUN sed -i 's|http://ports.ubuntu.com/ubuntu-ports|https://ports.ubuntu.com/ubuntu-ports|g' /etc/apt/sources.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends \
      openssh-server \
      openmpi-bin \
      libopenmpi-dev \
      build-essential \
      python3-dev \
    && rm -rf /var/lib/apt/lists/*

# Ensure mpi4py is built against Open MPI to match the MPIJob launcher using mpirun.openmpi.
# (Avoids "OMPI_COMM_WORLD_SIZE set, but mpi4py was built with MPICH" warnings.)
RUN python -m pip uninstall -y mpi4py || true \
    && MPICC=/usr/bin/mpicc.openmpi python -m pip install --no-cache-dir --no-binary=mpi4py mpi4py \
    && python -c "from mpi4py import MPI; print('mpi4py vendor:', MPI.get_vendor())"

# sshd needs host keys + runtime dir
RUN mkdir -p /var/run/sshd \
    && ssh-keygen -A \
    && sed -i 's/#PermitRootLogin prohibit-password/PermitRootLogin yes/' /etc/ssh/sshd_config \
    && sed -i 's/#PasswordAuthentication yes/PasswordAuthentication no/' /etc/ssh/sshd_config \
    && echo "StrictHostKeyChecking no" >> /etc/ssh/ssh_config \
    && echo "UserKnownHostsFile /dev/null" >> /etc/ssh/ssh_config

WORKDIR /workspace
COPY app/ /workspace/

# Clear the base image entrypoint.
ENTRYPOINT []

# Default to a shell; MPIJob will override commands for launcher/worker.
CMD ["bash"]
