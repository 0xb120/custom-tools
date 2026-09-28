import sys

def compare_files(file1_path, file2_path):
    """
    Compares two files line by line and prints lines that only appear in one file.
    
    Args:
        file1_path (str): Path to the first file
        file2_path (str): Path to the second file
    """
    try:
        # Read files and strip newlines
        with open(file1_path, 'r') as f1:
            file1_lines = {line.strip() for line in f1}
        
        with open(file2_path, 'r') as f2:
            file2_lines = {line.strip() for line in f2}
        
        # Find lines unique to each file
        only_in_file1 = file1_lines - file2_lines
        only_in_file2 = file2_lines - file1_lines
        
        # Print results
        if only_in_file1:
            print(f"\nLines only in {file1_path}:")
            for line in sorted(only_in_file1):
                print(f"  {line}")
        else:
            print(f"\nNo unique lines in {file1_path}")
            
        if only_in_file2:
            print(f"\nLines only in {file2_path}:")
            for line in sorted(only_in_file2):
                print(f"  {line}")
        else:
            print(f"\nNo unique lines in {file2_path}")
            
        # Summary
        if not only_in_file1 and not only_in_file2:
            print("\nThe files contain the same content (order may differ).")
            
    except FileNotFoundError as e:
        print(f"Error: {e}")
        sys.exit(1)
    except Exception as e:
        print(f"An error occurred: {e}")
        sys.exit(1)

def main():
    if len(sys.argv) != 3:
        print("Usage: python compare_files.py <file1> <file2>")
        sys.exit(1)
    
    file1_path = sys.argv[1]
    file2_path = sys.argv[2]
    
    compare_files(file1_path, file2_path)

if __name__ == "__main__":
    main()