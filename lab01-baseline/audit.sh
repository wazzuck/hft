echo "===OS==="
. /etc/os-release
echo "$PRETTY_NAME"

echo "$KERNEL"
uname -r

echo "===COMPILER==="
gcc --version | head -n 1

echo "===GIT==="
git --version

echo "===PYTHON==="
python3 --version

echo "===PROJECT==="
pwd

echo "===EXECUTION==="
./hello
